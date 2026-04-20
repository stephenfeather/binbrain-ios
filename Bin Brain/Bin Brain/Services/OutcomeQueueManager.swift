// OutcomeQueueManager.swift
// Bin Brain
//
// Offline-outcomes queue for Swift2_018. Persists every
// `POST /photos/{id}/outcomes` attempt as a `PendingOutcome` row and
// retries on a capped exponential schedule until the server accepts the
// payload, the request ages out of the 7-day TTL, or 20 retries are
// exhausted.
//
// The manager itself holds no long-lived references to a `ModelContext`
// or `APIClient`; callers pass both on every public method. This mirrors
// `UploadQueueManager` and keeps the manager unit-testable with an
// in-memory SwiftData container and a mocked URLSession.

import Foundation
import Network
import OSLog
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.binbrain.app", category: "OutcomeQueueManager")

// MARK: - OutcomeQueueManager

/// Drains the `PendingOutcome` queue with capped exponential backoff.
///
/// Not `@MainActor`-isolated: the `Observable` state is read by SwiftUI
/// views on the main thread but the actual drain loop runs wherever the
/// caller awaits. SwiftData `ModelContext` is assumed to be a main-thread
/// context — production callers pass `sharedModelContainer.mainContext`.
@Observable
final class OutcomeQueueManager {

    // MARK: - Tunables

    /// First-retry delay in seconds. Subsequent retries double.
    static let firstRetryDelay: TimeInterval = 30

    /// Cap on the backoff interval — 1 hour.
    static let maxRetryDelay: TimeInterval = 3600

    /// Maximum number of retries before a row is forced `.expired`.
    static let maxRetryCount: Int = 20

    /// TTL beyond which a row is expired regardless of status. 7 days.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Swift2_018c / SEC-26-2 — upper bound on rows reclaimed in a single
    /// `reclaimOrphanedSendingRows()` call. If a crash-loop somehow
    /// produced thousands of orphaned `.sending` rows, an unbounded
    /// reclaim would re-fire every one of them through the network at
    /// launch — turning a one-shot recovery into a denial of service
    /// against the user's own server. 100 rows is enough to recover
    /// from any plausible burst of in-flight outcomes (cataloging
    /// produces << 100 outcomes/min); the rest wait for the next launch
    /// (bounded forward progress).
    static let maxReclaimPerLaunch: Int = 100

    // MARK: - Observable counts (for Settings)

    private(set) var pendingCount: Int = 0
    private(set) var deliveredCount: Int = 0
    private(set) var expiredCount: Int = 0

    /// Swift2_018c / SEC-26-2 — true when the most recent
    /// `reclaimOrphanedSendingRows()` call hit `maxReclaimPerLaunch`
    /// and stopped early. Tested in `OutcomeQueueManagerTests` and
    /// surfaced as a `logger.warning` in production. Reset to `false`
    /// at the top of every reclaim call.
    private(set) var lastReclaimCapHit: Bool = false

    /// Swift2_018c / SEC-26-2 — number of `.sending` rows actually
    /// flipped to `.pending` by the most recent
    /// `reclaimOrphanedSendingRows()` call. Capped at
    /// `maxReclaimPerLaunch`. Useful for tests and (future) telemetry.
    private(set) var lastReclaimCount: Int = 0

    // MARK: - Test seams

    /// Overridable clock so tests can exercise time-dependent paths.
    var now: () -> Date = { Date() }

    // MARK: - Backoff

    /// Returns the retry delay (seconds) for the Nth failed attempt.
    ///
    /// Schedule: 30s, 1m, 2m, 4m, …, clamped to 1h. `retryCount = 0` returns
    /// `0` (first attempt fires immediately); negative values also return 0
    /// as a defensive fallback for any future corrupt persistence.
    static func backoff(retryCount: Int) -> TimeInterval {
        guard retryCount > 0 else { return 0 }
        // 30 * 2^(n-1). Compute via floating point and clamp — avoids the
        // `Int` overflow that would hit around retry 58 on 64-bit and keeps
        // the cap expression compact.
        let raw = firstRetryDelay * pow(2.0, Double(retryCount - 1))
        return min(raw, maxRetryDelay)
    }

    // MARK: - Public API

    /// Synchronously writes a `.pending` row and returns it.
    ///
    /// Split out from `enqueue` per QA finding F-2 (PR #23): the previous
    /// single async method let `confirm()` return before the underlying
    /// `Task` that wrapped `enqueue` had been scheduled, so an app-kill
    /// between `confirm()` returning and the Task running would lose
    /// the outcome entirely. Callers now `persist` synchronously from
    /// the confirm-path, then fire `deliver` in a detached Task.
    ///
    /// - Parameters:
    ///   - photoId: Server photo ID the outcomes belong to.
    ///   - payload: Already-encoded outcomes JSON body.
    ///   - context: Main-thread SwiftData context.
    /// - Returns: The persisted row, ready to hand to `deliver`.
    @discardableResult
    func persist(
        photoId: Int,
        payload: Data,
        context: ModelContext
    ) -> PendingOutcome {
        let row = PendingOutcome(photoId: photoId, payload: payload)
        context.insert(row)
        save(context)
        refreshCounts(context: context)
        return row
    }

    /// Attempts immediate delivery of a previously-persisted row. Safe
    /// to run fire-and-forget: exceptions are caught, status transitions
    /// happen against the persisted row, and the counts refresh after.
    ///
    /// Exposed so the confirm-path can separate the durable write
    /// (`persist`) from the network attempt, but still available as a
    /// single-step convenience via `enqueue`.
    func deliver(
        _ row: PendingOutcome,
        context: ModelContext,
        apiClient: APIClient
    ) async {
        await attemptDelivery(row, context: context, apiClient: apiClient)
    }

    /// Convenience wrapper that persists and attempts delivery in one call.
    ///
    /// Preserved so existing tests (and non-confirm callers that don't
    /// need the split) keep a single entry point. F-2's invariant —
    /// "row durable before confirm returns" — is upheld at the VM level
    /// by calling `persist` directly and spawning `deliver` in a Task.
    func enqueue(
        photoId: Int,
        payload: Data,
        context: ModelContext,
        apiClient: APIClient
    ) async {
        let row = persist(photoId: photoId, payload: payload, context: context)
        await attemptDelivery(row, context: context, apiClient: apiClient)
    }

    /// Processes every row whose `nextRetryAt <= now`, then sweeps TTL.
    ///
    /// Intended triggers: `NWPathMonitor` transition to `.satisfied`,
    /// `UIApplication.willEnterForegroundNotification`, and app launch.
    /// Expired rows are identified first so the sweep doesn't waste
    /// network on deliveries that would just be dropped.
    func drain(
        context: ModelContext,
        apiClient: APIClient
    ) async {
        expireAged(context: context)
        let nowDate = now()
        let ready: [PendingOutcome]
        do {
            let all = try context.fetch(FetchDescriptor<PendingOutcome>())
            ready = all
                .filter { $0.status == .pending && $0.nextRetryAt <= nowDate }
                .sorted { $0.queuedAt < $1.queuedAt }
        } catch {
            logger.error("[OUTCOMES] drain fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        for row in ready {
            await deliver(row, context: context, apiClient: apiClient)
        }
    }

    /// Forces every `.pending` row to attempt delivery NOW, ignoring
    /// `nextRetryAt`. Invoked from the Settings "Retry all" action.
    func retryAll(
        context: ModelContext,
        apiClient: APIClient
    ) async {
        expireAged(context: context)
        let rows: [PendingOutcome]
        do {
            let all = try context.fetch(FetchDescriptor<PendingOutcome>())
            rows = all.filter { $0.status == .pending }.sorted { $0.queuedAt < $1.queuedAt }
        } catch {
            logger.error("[OUTCOMES] retryAll fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        for row in rows {
            await deliver(row, context: context, apiClient: apiClient)
        }
    }

    /// Removes a single `.expired` row. Called from the Settings detail
    /// view's "Dismiss" action.
    func dismiss(_ outcome: PendingOutcome, context: ModelContext) {
        context.delete(outcome)
        save(context)
        refreshCounts(context: context)
    }

    /// Flips every `.sending` row back to `.pending` without touching
    /// `retryCount`. Call once per process at launch before the first
    /// `drain(...)` — `Bin_BrainApp` does this.
    ///
    /// Swift2_018b F-1 / SEC-23-1: `.sending` rows that the app
    /// crashed-in-flight previously leaked for 7 days until `expireAged`
    /// swept them to `.expired` with zero retries. Server is append-only
    /// (per F-6 client idempotency plan) — a duplicate POST is strictly
    /// preferable to a dropped training signal, so we do NOT bump
    /// `retryCount` on reclaim: callers can distinguish "crashed mid
    /// first attempt" from "retried normally" via the count.
    func reclaimOrphanedSendingRows(context: ModelContext) {
        lastReclaimCapHit = false
        lastReclaimCount = 0
        let all: [PendingOutcome]
        do {
            all = try context.fetch(FetchDescriptor<PendingOutcome>())
        } catch {
            logger.error("[OUTCOMES] reclaim fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        var reclaimed = 0
        for row in all where row.status == .sending {
            // Swift2_018c / SEC-26-2 — bounded reclaim per launch.
            // Stops a runaway crash-loop from re-firing every orphaned
            // row through the network at relaunch. Remaining rows wait
            // for the NEXT launch.
            if reclaimed >= Self.maxReclaimPerLaunch {
                lastReclaimCapHit = true
                logger.warning("[OUTCOMES] reclaim cap hit — \(reclaimed, privacy: .public) rows reclaimed in one launch; possible crash loop")
                break
            }
            row.status = .pending
            reclaimed += 1
        }
        lastReclaimCount = reclaimed
        if reclaimed > 0 {
            save(context)
            refreshCounts(context: context)
        }
    }

    /// Recomputes `pendingCount`, `deliveredCount`, and `expiredCount`
    /// from the persisted rows. Called after every mutation.
    func refreshCounts(context: ModelContext) {
        let all: [PendingOutcome]
        do {
            all = try context.fetch(FetchDescriptor<PendingOutcome>())
        } catch {
            logger.error("[OUTCOMES] refreshCounts fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        pendingCount = all.filter { $0.status == .pending }.count
        deliveredCount = all.filter { $0.status == .delivered }.count
        expiredCount = all.filter { $0.status == .expired }.count
    }

    // MARK: - Production wiring (not exercised in unit tests)

    #if canImport(UIKit)
    private var pathMonitor: NWPathMonitor?
    private var foregroundObserver: NSObjectProtocol?
    private var monitorQueue: DispatchQueue?
    /// Context + client stashed on self so the NWPathMonitor and
    /// NotificationCenter closures don't need to capture parameters
    /// directly — `ModelContext` is non-Sendable and capturing it in a
    /// `@Sendable` closure is a Swift-6 error. Accessed only from the
    /// main actor via `startMonitoring` / `runMonitoredDrain`.
    private var monitoringContext: ModelContext?
    private var monitoringAPIClient: APIClient?

    /// Starts the NWPathMonitor + willEnterForeground observers.
    ///
    /// Called once from `Bin_BrainApp` so the queue auto-drains on network
    /// recovery or when the app resumes. Idempotent — calling twice keeps
    /// the existing monitors.
    @MainActor
    func startMonitoring(
        context: ModelContext,
        apiClient: APIClient
    ) {
        guard pathMonitor == nil else { return }
        monitoringContext = context
        monitoringAPIClient = apiClient
        let queue = DispatchQueue(label: "com.binbrain.outcome-queue.path")
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                await self?.runMonitoredDrain()
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
        monitorQueue = queue

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runMonitoredDrain()
            }
        }
    }

    /// Tears down the monitors. Primarily for tests and future multi-user
    /// support — production calls `startMonitoring` once at launch.
    @MainActor
    func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        monitorQueue = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        foregroundObserver = nil
        monitoringContext = nil
        monitoringAPIClient = nil
    }

    @MainActor
    private func runMonitoredDrain() async {
        guard let monitoringContext, let monitoringAPIClient else { return }
        await drain(context: monitoringContext, apiClient: monitoringAPIClient)
    }
    #endif

    // MARK: - Delivery

    private func attemptDelivery(
        _ row: PendingOutcome,
        context: ModelContext,
        apiClient: APIClient
    ) async {
        // Swift2_018b F-3 / Swift2_018c G-1 + SEC-26-1 — CAS guard.
        //
        // Concurrent drain triggers (NWPathMonitor `.satisfied` +
        // willEnterForeground + scenePhase `.active`) can schedule two
        // `attemptDelivery` Tasks for the same row. The check-flip-save
        // below relies on running to completion between awaits so the
        // second Task sees `.sending` and returns early — only one POST
        // fires.
        //
        // *De-facto* MainActor isolation, NOT annotation-enforced:
        // `OutcomeQueueManager` is intentionally NOT `@MainActor` (the
        // SwiftData `ModelContext` is a main-thread context but the
        // class proper is non-isolated to keep `enqueue`/`drain`/
        // `retryAll` callable from arbitrary contexts). Every production
        // caller — `SuggestionReviewViewModel.fireOutcomesIfReady`,
        // `runMonitoredDrain`, the scenePhase observer in `Bin_BrainApp`
        // — routes through MainActor before invoking us, and that's
        // what makes the CAS atomic in practice. If a future caller
        // ever invokes `attemptDelivery` from a non-MainActor context,
        // it MUST add explicit serialization (actor, lock, or
        // MainActor.run wrapper) before the call, OR this guard must
        // be hardened with a real CAS primitive.
        guard row.status == .pending else { return }
        row.status = .sending
        save(context)

        let status: Int?
        var networkFailure = false
        do {
            status = try await apiClient.postPhotoSuggestionOutcomesRaw(
                photoId: row.photoId,
                body: row.payload,
                clientRetryCount: row.retryCount,
                idempotencyKey: row.id
            )
        } catch let urlError as URLError {
            row.lastErrorCode = urlError.code.rawValue
            status = nil
            networkFailure = true
            logger.error("[OUTCOMES] transport failure for photo \(row.photoId, privacy: .public): \(urlError.localizedDescription, privacy: .private)")
        } catch {
            row.lastErrorCode = nil
            status = nil
            networkFailure = true
            logger.error("[OUTCOMES] unexpected error for photo \(row.photoId, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }

        classify(row: row, status: status, networkFailure: networkFailure)
        save(context)
        refreshCounts(context: context)
    }

    private func classify(row: PendingOutcome, status: Int?, networkFailure: Bool) {
        if let status {
            row.lastErrorCode = status
            if (200...299).contains(status) {
                row.status = .delivered
                return
            }
            // 408 and 429 are transient even though they fall in 4xx.
            let retryableHTTP = status == 408 || status == 429 || (500...599).contains(status)
            if !retryableHTTP {
                row.status = .expired
                return
            }
        }
        // Retryable (5xx, 408/429, or transport error).
        row.retryCount += 1
        if row.retryCount >= Self.maxRetryCount {
            row.status = .expired
            return
        }
        row.status = .pending
        row.nextRetryAt = now().addingTimeInterval(Self.backoff(retryCount: row.retryCount))
        _ = networkFailure // logged above; explicitly ignored here
    }

    // MARK: - Sweeps

    private func expireAged(context: ModelContext) {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        let all: [PendingOutcome]
        do {
            all = try context.fetch(FetchDescriptor<PendingOutcome>())
        } catch {
            logger.error("[OUTCOMES] expireAged fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        var touched = false
        for row in all where row.queuedAt < cutoff {
            switch row.status {
            case .pending, .sending:
                // Surface the row in the Settings dead-letter so users
                // can see what failed. Leaves `.expired` rows alone —
                // dismissal is an explicit user action.
                row.status = .expired
                touched = true
            case .delivered:
                // F-4 (QA PR #23): delivered rows were retained forever.
                // Delete them after the 7-day TTL so the store stays
                // bounded. The user-visible "Delivered (last 7 days)"
                // count in Settings is now accurate by construction.
                context.delete(row)
                touched = true
            case .expired:
                // Keep — user will dismiss explicitly.
                break
            }
        }
        if touched {
            save(context)
            refreshCounts(context: context)
        }
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            logger.error("[OUTCOMES] context.save failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
