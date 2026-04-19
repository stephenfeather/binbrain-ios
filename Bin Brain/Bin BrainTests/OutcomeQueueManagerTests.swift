// OutcomeQueueManagerTests.swift
// Bin BrainTests
//
// XCTest coverage for the Swift2_018 offline-outcomes queue manager.
// All tests use a custom `URLProtocol` subclass to intercept every request
// — no real socket opens, no risk of polluting the production outcomes table.

import XCTest
import SwiftData
@testable import Bin_Brain

// MARK: - URL protocol mock

/// Distinct name (not `MockURLProtocol`) to avoid link-time collisions with
/// other test suites that install their own interceptors.
final class OutcomeQueueMockURLProtocol: URLProtocol {
    // Thread-safe handler storage so the URL loading thread can read the
    // handler while the test thread mutates it between scenarios.
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        handlerLock.lock(); defer { handlerLock.unlock() }
        _handler = handler
    }

    static func currentHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        handlerLock.lock(); defer { handlerLock.unlock() }
        return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - OutcomeQueueManagerTests

@MainActor
final class OutcomeQueueManagerTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    var sut: OutcomeQueueManager!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([PendingOutcome.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
        sut = OutcomeQueueManager()
    }

    override func tearDown() async throws {
        OutcomeQueueMockURLProtocol.setHandler(nil)
        sut = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        OutcomeQueueMockURLProtocol.setHandler(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutcomeQueueMockURLProtocol.self]
        return APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-key"])
        )
    }

    private func mockResponse(statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private var samplePayload: Data { Data("{\"vision_model\":\"test\"}".utf8) }

    // MARK: - enqueue happy path

    func testEnqueueSuccessMarksRowDelivered() async throws {
        var capturedHeader: String?
        let client = makeMockAPIClient { [self] request in
            capturedHeader = request.value(forHTTPHeaderField: "X-Client-Retry-Count")
            return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
        }

        await sut.enqueue(photoId: 7, payload: samplePayload, context: context, apiClient: client)

        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .delivered,
                       "2xx response must mark the row as delivered (mark+sweep)")
        XCTAssertEqual(rows.first?.photoId, 7)
        XCTAssertEqual(capturedHeader, "0",
                       "First-attempt POST must emit X-Client-Retry-Count: 0")
    }

    // MARK: - 5xx leaves row pending with incremented retryCount

    func testEnqueueServer500LeavesRowPendingAndIncrementsRetryCount() async throws {
        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 500, for: request), Data("{}".utf8))
        }

        let before = Date()
        await sut.enqueue(photoId: 7, payload: samplePayload, context: context, apiClient: client)

        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.status, .pending, "5xx must leave the row pending for retry")
        XCTAssertEqual(row.retryCount, 1, "First 5xx increments retryCount to 1")
        XCTAssertEqual(row.lastErrorCode, 500, "HTTP status recorded for Settings detail view")
        XCTAssertGreaterThan(row.nextRetryAt, before,
                             "Backoff must push nextRetryAt into the future")
    }

    // MARK: - 422 is non-retryable → .expired

    func testEnqueue422MarksRowExpiredImmediately() async throws {
        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 422, for: request), Data("{}".utf8))
        }

        await sut.enqueue(photoId: 1, payload: samplePayload, context: context, apiClient: client)

        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingOutcome>()).first)
        XCTAssertEqual(row.status, .expired,
                       "Validator 422 is a client bug — retrying is futile")
        XCTAssertEqual(row.lastErrorCode, 422)
    }

    // MARK: - 408 / 429 are retryable

    func testEnqueue408LeavesRowPending() async throws {
        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 408, for: request), Data())
        }

        await sut.enqueue(photoId: 1, payload: samplePayload, context: context, apiClient: client)

        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingOutcome>()).first)
        XCTAssertEqual(row.status, .pending,
                       "408 Request Timeout is transient — must stay pending for retry")
        XCTAssertEqual(row.retryCount, 1)
        XCTAssertEqual(row.lastErrorCode, 408)
    }

    func testEnqueue429LeavesRowPending() async throws {
        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 429, for: request), Data())
        }

        await sut.enqueue(photoId: 1, payload: samplePayload, context: context, apiClient: client)

        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingOutcome>()).first)
        XCTAssertEqual(row.status, .pending,
                       "429 Too Many Requests is transient — client-side backoff covers it")
        XCTAssertEqual(row.retryCount, 1)
    }

    // MARK: - Network (URLError) is retryable

    func testEnqueueNetworkErrorLeavesRowPending() async throws {
        let client = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sut.enqueue(photoId: 1, payload: samplePayload, context: context, apiClient: client)

        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingOutcome>()).first)
        XCTAssertEqual(row.status, .pending,
                       "Transport failure is the canonical retry case — queue keeps it for NWPathMonitor sweep")
        XCTAssertEqual(row.retryCount, 1)
    }

    // MARK: - Retry count echoed on subsequent attempts

    func testDrainEmitsIncrementedRetryCountHeader() async throws {
        // Seed a row that failed once already.
        let row = PendingOutcome(photoId: 11, payload: samplePayload)
        row.retryCount = 3
        row.status = .pending
        row.nextRetryAt = Date().addingTimeInterval(-1) // ready to retry now
        context.insert(row)
        try context.save()

        var capturedHeader: String?
        let client = makeMockAPIClient { [self] request in
            capturedHeader = request.value(forHTTPHeaderField: "X-Client-Retry-Count")
            return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
        }

        await sut.drain(context: context, apiClient: client)

        XCTAssertEqual(capturedHeader, "3",
                       "Retry attempt must echo the accumulated retry count to the server")
        let refreshed = try context.fetch(FetchDescriptor<PendingOutcome>()).first
        XCTAssertEqual(refreshed?.status, .delivered)
    }

    // MARK: - 20-retry cap

    func testTwentyFailedRetriesForceExpired() async throws {
        let row = PendingOutcome(photoId: 11, payload: samplePayload)
        row.retryCount = 19
        row.nextRetryAt = Date().addingTimeInterval(-1)
        context.insert(row)
        try context.save()

        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 500, for: request), Data())
        }

        await sut.drain(context: context, apiClient: client)

        let refreshed = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingOutcome>()).first)
        XCTAssertEqual(refreshed.retryCount, 20)
        XCTAssertEqual(refreshed.status, .expired,
                       "20th consecutive failure must force .expired — bounded even if network is permanently hostile")
    }

    // MARK: - 7-day TTL expiration sweep

    func testExpirationSweepMarksOldRowsExpired() async throws {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let fresh = PendingOutcome(photoId: 1, payload: samplePayload)
        let stale = PendingOutcome(photoId: 2, payload: samplePayload)
        stale.queuedAt = eightDaysAgo
        context.insert(fresh)
        context.insert(stale)
        try context.save()

        let client = makeMockAPIClient { [self] request in
            // The stale row never hits the wire — it is expired before any
            // POST. The fresh row has nextRetryAt == queuedAt ≈ now, so it
            // IS eligible and will be delivered successfully; this test
            // only asserts the stale row's expiry behaviour.
            (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
        }

        await sut.drain(context: context, apiClient: client)

        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        let staleRow = try XCTUnwrap(rows.first(where: { $0.photoId == 2 }))
        XCTAssertEqual(staleRow.status, .expired,
                       "Row older than 7 days must be expired on sweep")
    }

    // MARK: - retryAll forces pending rows regardless of nextRetryAt

    func testRetryAllIgnoresNextRetryAt() async throws {
        let row = PendingOutcome(photoId: 1, payload: samplePayload)
        row.retryCount = 2
        row.nextRetryAt = Date().addingTimeInterval(600) // 10m in the future
        context.insert(row)
        try context.save()

        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
        }

        await sut.retryAll(context: context, apiClient: client)

        let refreshed = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingOutcome>()).first)
        XCTAssertEqual(refreshed.status, .delivered,
                       "retryAll must bypass nextRetryAt so user-initiated retries fire immediately")
    }

    // MARK: - drain skips rows not yet due

    func testDrainSkipsRowsBeforeNextRetryAt() async throws {
        let row = PendingOutcome(photoId: 1, payload: samplePayload)
        row.retryCount = 2
        row.nextRetryAt = Date().addingTimeInterval(600) // 10m in the future
        context.insert(row)
        try context.save()

        var posts = 0
        let client = makeMockAPIClient { [self] request in
            posts += 1
            return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
        }

        await sut.drain(context: context, apiClient: client)

        XCTAssertEqual(posts, 0,
                       "drain must respect nextRetryAt — user-visible retryAll is the escape hatch")
        let refreshed = try XCTUnwrap(try context.fetch(FetchDescriptor<PendingOutcome>()).first)
        XCTAssertEqual(refreshed.status, .pending)
    }

    // MARK: - dismiss deletes an expired row

    func testDismissDeletesExpiredRow() async throws {
        let row = PendingOutcome(photoId: 1, payload: samplePayload)
        row.status = .expired
        context.insert(row)
        try context.save()

        sut.dismiss(row, context: context)

        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertTrue(rows.isEmpty, "Dismiss must remove the expired row from storage")
    }

    // MARK: - F-2: persist is synchronous

    /// F-2 (QA PR #23): `persist(...)` writes the row to SwiftData
    /// synchronously — no await, no Task scheduling. This is what lets
    /// `SuggestionReviewViewModel.confirm()` return with the row durable
    /// so an app-kill cannot drop the outcome.
    func testPersistIsSynchronousAndRowIsImmediatelyQueryable() throws {
        let row = sut.persist(photoId: 99, payload: samplePayload, context: context)

        // Same tick: fetch and find it.
        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(rows.count, 1,
                       "persist must synchronously commit the row — no awaits in the write path")
        XCTAssertEqual(rows.first?.id, row.id)
        XCTAssertEqual(rows.first?.photoId, 99)
        XCTAssertEqual(rows.first?.status, .pending)
    }

    // MARK: - F-4: delivered-row TTL sweep

    /// F-4 (QA PR #23): delivered rows used to accumulate forever
    /// because `expireAged` excluded `.delivered`. The TTL sweep now
    /// deletes delivered rows past the 7-day cutoff so the store stays
    /// bounded without a separate janitor.
    func testExpirationSweepDeletesDeliveredRowsPastTTL() async throws {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let freshDelivered = PendingOutcome(photoId: 1, payload: samplePayload)
        freshDelivered.status = .delivered
        let staleDelivered = PendingOutcome(photoId: 2, payload: samplePayload)
        staleDelivered.status = .delivered
        staleDelivered.queuedAt = eightDaysAgo
        context.insert(freshDelivered)
        context.insert(staleDelivered)
        try context.save()

        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
        }

        await sut.drain(context: context, apiClient: client)

        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        let ids = Set(rows.map(\.photoId))
        XCTAssertTrue(ids.contains(1),
                      "Fresh delivered row (< 7 days) must be retained")
        XCTAssertFalse(ids.contains(2),
                       "Stale delivered row (> 7 days) must be deleted, not merely flipped to .expired")
    }

    /// Expired rows stay put — dismissal is an explicit user action,
    /// not a TTL behaviour.
    func testExpirationSweepLeavesExpiredRowsAlone() async throws {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let staleExpired = PendingOutcome(photoId: 3, payload: samplePayload)
        staleExpired.status = .expired
        staleExpired.queuedAt = eightDaysAgo
        context.insert(staleExpired)
        try context.save()

        let client = makeMockAPIClient { [self] request in
            (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
        }

        await sut.drain(context: context, apiClient: client)

        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(rows.first?.status, .expired,
                       "Expired rows persist until the user dismisses them explicitly")
    }

    // MARK: - Observable counts

    func testCountsReflectPersistedRows() async throws {
        let pending = PendingOutcome(photoId: 1, payload: samplePayload)
        let delivered = PendingOutcome(photoId: 2, payload: samplePayload)
        delivered.status = .delivered
        let expired = PendingOutcome(photoId: 3, payload: samplePayload)
        expired.status = .expired
        context.insert(pending)
        context.insert(delivered)
        context.insert(expired)
        try context.save()

        sut.refreshCounts(context: context)

        XCTAssertEqual(sut.pendingCount, 1)
        XCTAssertEqual(sut.deliveredCount, 1)
        XCTAssertEqual(sut.expiredCount, 1)
    }
}
