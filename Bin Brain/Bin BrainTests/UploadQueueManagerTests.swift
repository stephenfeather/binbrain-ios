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
    return APIClient(session: URLSession(configuration: config))
}

private let successIngestJSON = Data("""
{
    "version": "1",
    "bin_id": "BIN-0001",
    "photos": [{ "photo_id": 1, "path": "/data/photos/BIN-0001/abc.jpg" }]
}
""".utf8)

// MARK: - UploadQueueManagerTests

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

    // MARK: - Test 5: Drain failure with retryCount == 2 marks upload as failed

    /// When `retryCount` is already 2 and ingest fails, the upload reaches the threshold
    /// and is marked `.failed` (retryCount >= 3).
    func testDrainFailureAfter3RetriesMarksFailed() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        upload.retryCount = 2
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        let item = try XCTUnwrap(remaining.first)
        XCTAssertEqual(item.retryCount, 3)
        XCTAssertEqual(item.status, .failed, "Upload at retry threshold should become .failed")
    }

    // MARK: - Test 6: Drain failure below threshold keeps upload pending

    /// When `retryCount` is 0 and ingest fails (retryCount becomes 1), the status
    /// reverts to `.pending` since the retry threshold has not been reached.
    func testDrainFailureBelowThresholdKeepsPending() async throws {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        // retryCount starts at 0; after one failure it becomes 1, still below threshold of 3.
        context.insert(upload)
        try context.save()

        let apiClient = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sut.drain(context: context, using: apiClient)

        let remaining = try context.fetch(FetchDescriptor<PendingUpload>())
        let item = try XCTUnwrap(remaining.first)
        XCTAssertEqual(item.status, .pending, "Upload below retry threshold should stay .pending")
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
}
