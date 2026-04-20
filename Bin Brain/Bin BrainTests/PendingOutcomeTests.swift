// PendingOutcomeTests.swift
// Bin BrainTests
//
// SwiftData CRUD coverage for the Swift2_018 offline-outcomes queue model.
// All tests use an in-memory ModelContainer to avoid touching the file
// system or any device state.

import XCTest
import SwiftData
@testable import Bin_Brain

final class PendingOutcomeTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([PendingOutcome.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - Defaults

    func testDefaultInitialisationSetsExpectedValues() {
        let before = Date()
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let row = PendingOutcome(photoId: 42, payload: payload)
        let after = Date()

        XCTAssertEqual(row.photoId, 42)
        XCTAssertEqual(row.payload, payload)
        XCTAssertEqual(row.retryCount, 0)
        XCTAssertEqual(row.status, .pending)
        XCTAssertNil(row.lastErrorCode)
        XCTAssertGreaterThanOrEqual(row.queuedAt, before)
        XCTAssertLessThanOrEqual(row.queuedAt, after)
        XCTAssertEqual(row.nextRetryAt, row.queuedAt,
                       "First attempt has no backoff — nextRetryAt mirrors queuedAt")
    }

    // MARK: - UUID uniqueness

    func testIdsAreUniquePerInstance() {
        let a = PendingOutcome(photoId: 1, payload: Data([0]))
        let b = PendingOutcome(photoId: 2, payload: Data([1]))
        XCTAssertNotEqual(a.id, b.id, "Two constructed rows must have distinct client-side UUIDs")
    }

    // MARK: - Persistence

    func testRowSurvivesInsertAndFetch() throws {
        let row = PendingOutcome(photoId: 7, payload: Data([0xCA, 0xFE]))
        context.insert(row)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.photoId, 7)
        XCTAssertEqual(fetched.first?.status, .pending)
    }

    // MARK: - Status transitions

    func testStatusTransitionsThroughLifecycle() {
        let row = PendingOutcome(photoId: 1, payload: Data([0]))
        XCTAssertEqual(row.status, .pending)

        row.status = .sending
        XCTAssertEqual(row.status, .sending)

        row.status = .delivered
        XCTAssertEqual(row.status, .delivered)
    }

    func testStatusExpiredIsTerminal() {
        let row = PendingOutcome(photoId: 1, payload: Data([0]))
        row.status = .expired
        XCTAssertEqual(row.status, .expired)
    }

    // MARK: - Backoff math (pure function on the manager)

    func testBackoffStartsAt30Seconds() {
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 1), 30)
    }

    func testBackoffDoublesPerRetry() {
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 2), 60)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 3), 120)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 4), 240)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 5), 480)
    }

    func testBackoffCapsAtOneHour() {
        // 30 * 2^(n-1): crosses 3600s between retry 7 (1920) and retry 8 (3840).
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 7), 1920)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 8), 3600,
                       "Backoff must clamp at 1h regardless of retry count")
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 20), 3600,
                       "20th retry must still clamp at 1h — no overflow")
    }

    func testBackoffZeroOrNegativeReturnsImmediate() {
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 0), 0,
                       "retryCount=0 means first attempt; no backoff required")
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: -1), 0,
                       "Negative retryCount defends against corrupt persistence")
    }

    // MARK: - F-5: on-disk persistence round-trip

    /// Swift2_018b F-5. The whole point of the `PendingOutcome` queue is
    /// that it "survives app termination" (see the file header comment).
    /// Every prior test uses `isStoredInMemoryOnly: true` — that never
    /// exercises the SQLite write path, the store-file format, or the
    /// `@Attribute(.unique)` enforcement. This test creates a file-backed
    /// `ModelContainer` in a tempdir, writes a row through container1,
    /// tears container1 down (simulated app exit), opens container2
    /// against the same URL, and asserts the row is intact.
    func testRowSurvivesContainerTeardownAndRelaunch() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingoutcome-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            let wal = tempURL.appendingPathExtension("wal")
            let shm = tempURL.appendingPathExtension("shm")
            try? FileManager.default.removeItem(at: wal)
            try? FileManager.default.removeItem(at: shm)
        }

        // Launch 1 — write a row and tear down.
        let originalId: UUID
        do {
            let schema = Schema([PendingOutcome.self])
            let config = ModelConfiguration(schema: schema, url: tempURL)
            let container1 = try ModelContainer(for: schema, configurations: config)
            let ctx1 = ModelContext(container1)
            let row = PendingOutcome(photoId: 77, payload: Data("{\"hi\":1}".utf8))
            row.retryCount = 4
            originalId = row.id
            ctx1.insert(row)
            try ctx1.save()
            // container1 released when scope ends — simulates app exit.
        }

        // Launch 2 — open the same on-disk store and fetch the row.
        let schema = Schema([PendingOutcome.self])
        let config = ModelConfiguration(schema: schema, url: tempURL)
        let container2 = try ModelContainer(for: schema, configurations: config)
        let ctx2 = ModelContext(container2)
        let rows = try ctx2.fetch(FetchDescriptor<PendingOutcome>())

        XCTAssertEqual(rows.count, 1,
                       "PendingOutcome must persist across ModelContainer teardown — the queue's whole guarantee")
        XCTAssertEqual(rows.first?.id, originalId,
                       "UUID identity must round-trip through SQLite")
        XCTAssertEqual(rows.first?.photoId, 77)
        XCTAssertEqual(rows.first?.retryCount, 4)
        XCTAssertEqual(rows.first?.status, .pending,
                       "Int raw value of the status enum must round-trip — frozen values per PendingOutcome doc")
    }

    // MARK: - Swift2_018c G-2 — expanded on-disk round-trip

    /// Helper: opens a file-backed container, runs `seed`, tears it down,
    /// reopens, and returns the rebuilt rows. `seed` runs against a fresh
    /// `ModelContext` paired with the launch-1 container.
    private func roundTripOnDisk<R>(
        seed: (ModelContext) throws -> R,
        verify: (ModelContext) throws -> Void
    ) throws -> R {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingoutcome-rt-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
        }
        let result: R
        do {
            let schema = Schema([PendingOutcome.self])
            let config = ModelConfiguration(schema: schema, url: tempURL)
            let container1 = try ModelContainer(for: schema, configurations: config)
            let ctx1 = ModelContext(container1)
            result = try seed(ctx1)
            try ctx1.save()
        }
        let schema = Schema([PendingOutcome.self])
        let config = ModelConfiguration(schema: schema, url: tempURL)
        let container2 = try ModelContainer(for: schema, configurations: config)
        let ctx2 = ModelContext(container2)
        try verify(ctx2)
        return result
    }

    /// QA PR #26 §178–190 — payload Data must survive the SQLite write
    /// path byte-for-byte, including arbitrary binary content.
    func testPayloadRoundTripsByteForByte() throws {
        let payload = Data((0...255).map { UInt8($0) })  // every possible byte
        try roundTripOnDisk(
            seed: { ctx in
                let row = PendingOutcome(photoId: 1, payload: payload)
                ctx.insert(row)
            },
            verify: { ctx in
                let rows = try ctx.fetch(FetchDescriptor<PendingOutcome>())
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows.first?.payload, payload,
                               "payload Data must round-trip every byte 0x00-0xFF")
            }
        )
    }

    /// QA PR #26 §178–190 — queuedAt and nextRetryAt timestamps must
    /// round-trip without drifting (small tolerance for SwiftData's
    /// Date precision).
    func testDatesRoundTripThroughStore() throws {
        let queuedAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        let nextRetryAt = queuedAt.addingTimeInterval(3600)
        try roundTripOnDisk(
            seed: { ctx in
                let row = PendingOutcome(photoId: 1, payload: Data())
                row.queuedAt = queuedAt
                row.nextRetryAt = nextRetryAt
                ctx.insert(row)
            },
            verify: { ctx in
                let rows = try ctx.fetch(FetchDescriptor<PendingOutcome>())
                let row = try XCTUnwrap(rows.first)
                XCTAssertEqual(row.queuedAt.timeIntervalSinceReferenceDate,
                               queuedAt.timeIntervalSinceReferenceDate,
                               accuracy: 0.001,
                               "queuedAt must round-trip within sub-millisecond tolerance")
                XCTAssertEqual(row.nextRetryAt.timeIntervalSinceReferenceDate,
                               nextRetryAt.timeIntervalSinceReferenceDate,
                               accuracy: 0.001,
                               "nextRetryAt must round-trip within sub-millisecond tolerance")
            }
        )
    }

    /// QA PR #26 §178–190 — `lastErrorCode` is `Int?` and the nil case
    /// is the most common (default on every fresh row). Both nil and
    /// a non-nil value must round-trip.
    func testLastErrorCodeNilRoundTrips() throws {
        try roundTripOnDisk(
            seed: { ctx in
                let row = PendingOutcome(photoId: 1, payload: Data())
                row.lastErrorCode = nil
                ctx.insert(row)
            },
            verify: { ctx in
                let rows = try ctx.fetch(FetchDescriptor<PendingOutcome>())
                XCTAssertNil(rows.first?.lastErrorCode,
                             "lastErrorCode nil must persist as nil — Optional<Int> column must not coerce to 0")
            }
        )
    }

    func testLastErrorCodeNonNilRoundTrips() throws {
        try roundTripOnDisk(
            seed: { ctx in
                let row = PendingOutcome(photoId: 1, payload: Data())
                row.lastErrorCode = 500
                ctx.insert(row)
            },
            verify: { ctx in
                let rows = try ctx.fetch(FetchDescriptor<PendingOutcome>())
                XCTAssertEqual(rows.first?.lastErrorCode, 500,
                               "non-nil lastErrorCode must round-trip exactly")
            }
        )
    }

    /// QA PR #26 §192–200 — every OutcomeQueueStatus raw value must
    /// round-trip. Frozen-int contract per the model's doc comment.
    func testAllStatusRawValuesRoundTrip() throws {
        for status in [OutcomeQueueStatus.pending, .sending, .delivered, .expired] {
            try roundTripOnDisk(
                seed: { ctx in
                    let row = PendingOutcome(photoId: status.rawValue, payload: Data())
                    row.status = status
                    ctx.insert(row)
                },
                verify: { ctx in
                    let rows = try ctx.fetch(FetchDescriptor<PendingOutcome>())
                    XCTAssertEqual(rows.first?.status, status,
                                   "OutcomeQueueStatus.\(status) raw value (\(status.rawValue)) must round-trip exactly")
                }
            )
        }
    }
}
