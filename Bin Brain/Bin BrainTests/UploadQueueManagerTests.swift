// UploadQueueManagerTests.swift
// Bin BrainTests
//
// XCTest coverage for UploadQueueManager using an in-memory SwiftData store
// and a mock URLSession-backed APIClient. MockURLProtocol is redefined here
// with a distinct name to avoid symbol collision with APIClientTests.

import XCTest
import SwiftData
@testable import Bin_Brain

// MARK: - UploadQueueMockURLProtocol

/// A URLProtocol subclass that intercepts all requests during UploadQueueManager tests.
///
/// Set `requestHandler` before each test and clear it in `tearDown`.
final class UploadQueueMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = UploadQueueMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
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

// MARK: - Helpers

private func makeMockResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://mock")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

private func makeMockAPIClient(
    handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil
) -> APIClient {
    if let handler { UploadQueueMockURLProtocol.requestHandler = handler }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UploadQueueMockURLProtocol.self]
    return APIClient(
        session: URLSession(configuration: config),
        keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-key"])
    )
}

private let successIngestJSON = Data("""
{
    "version": "1",
    "bin_id": "BIN-0001",
    "photos": [{ "photo_id": 1, "url": "/photos/1/file" }]
}
""".utf8)

// MARK: - UploadQueueManagerTests

@MainActor
final class UploadQueueManagerTests: XCTestCase {

    // MARK: - Setup

    var container: ModelContainer!
    var context: ModelContext!
    var sut: UploadQueueManager!

    override func setUp() async throws {
        let schema = Schema([PendingUpload.self, PendingAnalysis.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
        sut = UploadQueueManager()
    }

    override func tearDown() async throws {
        UploadQueueMockURLProtocol.requestHandler = nil
        container = nil
        context = nil
        sut = nil
    }

    // MARK: - Test 1: Initial state

    /// Fresh `UploadQueueManager` reports zero pending items.
    func testInitialPendingCountIsZero() {
        XCTAssertEqual(sut.pendingCount, 0)
    }

    // MARK: - Test 2: refreshCount counts pending and failed, but not uploading

    /// `refreshCount` counts `.pending` + `.failed` rows but ignores `.uploading`.
    func testRefreshCountReflectsPendingAndFailed() throws {
        let pending1 = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        let pending2 = PendingUpload(jpegData: Data([0x02]), binId: "BIN-0002")
        let failed = PendingUpload(jpegData: Data([0x03]), binId: "BIN-0003")
        failed.status = .failed
        let uploading = PendingUpload(jpegData: Data([0x04]), binId: "BIN-0004")
        uploading.status = .uploading

        context.insert(pending1)
        context.insert(pending2)
        context.insert(failed)
        context.insert(uploading)
        try context.save()

        sut.refreshCount(context: context)

        XCTAssertEqual(sut.pendingCount, 3, "Should count 2 pending + 1 failed, not the 1 uploading")
    }

    // MARK: - Test 3: Drain success deletes the upload

    /// When `apiClient.ingest` succeeds, `drain` deletes the upload and reports `pendingCount == 0`.
    func testDrainSuccessDeletesUpload() async throws {
        let upload = PendingUpload(jpegData: Data([0xFF, 0xD8]), binId: "BIN-0001")
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(remaining.count, 0, "Successful upload should be removed from queue")
        XCTAssertEqual(sut.pendingCount, 0)
    }

    // MARK: - Test 4: Drain failure increments retryCount

    /// When `apiClient.ingest` throws, `drain` increments `retryCount` by one.
    func testDrainFailureIncrementsRetryCount() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        let item = try XCTUnwrap(remaining.first)
        XCTAssertEqual(item.retryCount, 1, "retryCount should be incremented by 1 on each failure")
    }

    // MARK: - Test 5: Drain failure keeps upload pending (no hard cap)

    /// Failed uploads always remain `.pending` for the next drain cycle.
    /// Time-based expiry (7 days) replaces the old 3-retry hard cap.
    func testDrainFailureKeepsUploadPending() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        upload.retryCount = 5
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        sut.sleepForInterval = { _ in } // skip actual delays

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        let item = try XCTUnwrap(remaining.first)
        XCTAssertEqual(item.retryCount, 6)
        XCTAssertEqual(item.status, .pending, "Failed uploads should stay .pending regardless of retry count")
    }

    // MARK: - Test 6: Drain failure increments retryCount and stays pending

    /// When `retryCount` is 0 and ingest fails (retryCount becomes 1), the status
    /// stays `.pending` for the next drain cycle.
    func testDrainFailureBelowThresholdKeepsPending() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        let item = try XCTUnwrap(remaining.first)
        XCTAssertEqual(item.status, .pending, "Upload should stay .pending after failure")
    }

    // MARK: - Test 7: clearQueue deletes all uploads

    /// `clearQueue` removes every `PendingUpload` row regardless of status and resets `pendingCount`.
    func testClearQueueDeletesAll() throws {
        let pending = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        let failed = PendingUpload(jpegData: Data([0x02]), binId: "BIN-0002")
        failed.status = .failed
        let uploading = PendingUpload(jpegData: Data([0x03]), binId: "BIN-0003")
        uploading.status = .uploading

        context.insert(pending)
        context.insert(failed)
        context.insert(uploading)
        try context.save()

        sut.clearQueue(context: context)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(remaining.count, 0, "clearQueue should delete all uploads regardless of status")
        XCTAssertEqual(sut.pendingCount, 0)
    }

    // MARK: - Test 8: Drain only processes pending, not failed

    /// `drain` fetches only `.pending` uploads; `.failed` uploads are left untouched.
    func testDrainOnlyProcessesPendingNotFailed() async throws {
        let pending = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        let failed = PendingUpload(jpegData: Data([0x02]), binId: "BIN-0002")
        failed.status = .failed
        context.insert(pending)
        context.insert(failed)
        try context.save()

        var ingestCallCount = 0
        let apiClient = makeMockAPIClient { _ in
            ingestCallCount += 1
            return (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(remaining.count, 1, "Only the failed upload should remain after drain")
        let remainingItem = try XCTUnwrap(remaining.first)
        XCTAssertEqual(remainingItem.status, .failed, "Untouched item should still be .failed")
        XCTAssertEqual(ingestCallCount, 1, "ingest should be called once — for the pending upload only")
    }

    // MARK: - Test 9: Drain with metadata succeeds and deletes upload

    /// When a `PendingUpload` has `deviceMetadataJSON`, `drain` successfully uploads
    /// and deletes the entry. (Body content verification is covered by APIClientTests.)
    func testDrainWithMetadataSucceedsAndDeletes() async throws {
        let metadata = "{\"device_processing\":{\"version\":\"1\"}}"
        let upload = PendingUpload(
            jpegData: Data([0xFF, 0xD8]),
            binId: "BIN-0001",
            deviceMetadataJSON: metadata
        )
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(remaining.count, 0, "Upload with metadata should be removed after success")
        XCTAssertEqual(sut.pendingCount, 0)
    }

    // MARK: - Test 10: Drain without metadata succeeds and deletes upload

    /// When `deviceMetadataJSON` is nil, `drain` still succeeds and deletes the upload.
    func testDrainWithoutMetadataSucceedsAndDeletes() async throws {
        let upload = PendingUpload(jpegData: Data([0xFF, 0xD8]), binId: "BIN-0001")
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(remaining.count, 0, "Upload without metadata should be removed after success")
        XCTAssertEqual(sut.pendingCount, 0)
    }

    // MARK: - Test 11: Exponential backoff delays

    /// Verifies that backoff delays match the expected schedule [5, 15, 45, 120].
    func testBackoffDelaysAppliedOnRetry() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        upload.retryCount = 2 // Should trigger backoffDelays[1] = 15s
        context.insert(upload)
        try context.save()

        var capturedDelay: TimeInterval = 0
        sut.sleepForInterval = { interval in
            capturedDelay = interval
        }

        let apiClient = makeMockAPIClient { _ in
            (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        XCTAssertEqual(capturedDelay, 15, accuracy: 0.01, "retryCount 2 should use backoffDelays[1] = 15s")
    }

    /// No delay is applied on the first attempt (retryCount == 0).
    func testNoBackoffOnFirstAttempt() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        context.insert(upload)
        try context.save()

        var sleepCalled = false
        sut.sleepForInterval = { _ in
            sleepCalled = true
        }

        let apiClient = makeMockAPIClient { _ in
            (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        XCTAssertFalse(sleepCalled, "No backoff delay should be applied on first attempt")
    }

    /// Backoff delay clamps to the last value for high retry counts.
    func testBackoffClampsToMaxDelay() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        upload.retryCount = 100 // Way beyond the array length
        context.insert(upload)
        try context.save()

        var capturedDelay: TimeInterval = 0
        sut.sleepForInterval = { interval in
            capturedDelay = interval
        }

        let apiClient = makeMockAPIClient { _ in
            (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        XCTAssertEqual(capturedDelay, 120, accuracy: 0.01, "High retry counts should clamp to max delay of 120s")
    }

    // MARK: - Test 12: 7-day expiry pruning

    /// Uploads older than 7 days are pruned on each `drain()` call.
    func testPruneExpiredRemovesOldEntries() async throws {
        let oldUpload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-OLD")
        // Manually set queuedAt to 8 days ago
        oldUpload.queuedAt = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let freshUpload = PendingUpload(jpegData: Data([0x02]), binId: "BIN-FRESH")

        context.insert(oldUpload)
        context.insert(freshUpload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            (makeMockResponse(statusCode: 200), successIngestJSON)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        // Fresh upload was processed successfully and deleted; old upload was pruned.
        XCTAssertEqual(remaining.count, 0, "Both old (pruned) and fresh (uploaded) should be gone")
    }

    /// Uploads within 7 days are NOT pruned.
    func testPruneExpiredKeepsRecentEntries() throws {
        let recentUpload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-RECENT")
        recentUpload.queuedAt = Date().addingTimeInterval(-6 * 24 * 60 * 60) // 6 days ago
        context.insert(recentUpload)
        try context.save()

        sut.pruneExpired(context: context)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(remaining.count, 1, "Upload within 7 days should NOT be pruned")
    }

    /// Pruning uses the injectable `now()` for time calculation.
    func testPruneUsesInjectableNow() throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        upload.queuedAt = Date() // Queued "now" in real time
        context.insert(upload)
        try context.save()

        // Pretend it's 8 days in the future
        sut.now = { Date().addingTimeInterval(8 * 24 * 60 * 60) }

        sut.pruneExpired(context: context)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(remaining.count, 0, "Upload should be pruned when 'now' is 8 days later")
    }
}
