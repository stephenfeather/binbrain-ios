// BinsListViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for BinsListViewModel.swift.
// BinsListView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in BinsListViewModel.

import XCTest
@testable import Bin_Brain

// MARK: - BinsListMockURLProtocol

/// A URLProtocol subclass that intercepts all requests for BinsListViewModel tests.
///
/// Uses a distinct name to avoid symbol collisions with other mock protocols.
final class BinsListMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = BinsListMockURLProtocol.requestHandler else {
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

// MARK: - BinsListViewModelTests

final class BinsListViewModelTests: XCTestCase {

    var sut: BinsListViewModel!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = BinsListViewModel()
    }

    override func tearDown() async throws {
        BinsListMockURLProtocol.requestHandler = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        BinsListMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BinsListMockURLProtocol.self]
        return APIClient(session: URLSession(configuration: config))
    }

    private func mockResponse(statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private var listBinsSuccessJSON: Data {
        Data("""
        {
            "version": "1",
            "bins": [
                {"bin_id": "BIN-0001", "item_count": 3, "photo_count": 2, "last_updated": "2026-02-25T20:00:00Z"},
                {"bin_id": "BIN-0002", "item_count": 1, "photo_count": 1, "last_updated": "2026-02-24T10:00:00Z"}
            ]
        }
        """.utf8)
    }

    private var serverErrorJSON: Data {
        Data("""
        {"version":"1","error":{"code":"server_error","message":"Internal server error"}}
        """.utf8)
    }

    // MARK: - Test 1: Initial state

    func testInitialState() {
        XCTAssertTrue(sut.bins.isEmpty, "bins should be empty on init")
        XCTAssertFalse(sut.isLoading, "isLoading should be false on init")
        XCTAssertNil(sut.error, "error should be nil on init")
    }

    // MARK: - Test 2: Load populates bins

    func testLoadPopulatesBins() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), listBinsSuccessJSON)
        }

        await sut.load(apiClient: client)

        XCTAssertEqual(sut.bins.count, 2, "Should have 2 bins after successful load")
        XCTAssertFalse(sut.isLoading, "isLoading should be false after load")
        XCTAssertNil(sut.error, "error should be nil after successful load")
    }

    // MARK: - Test 3: Load sets error on failure

    func testLoadSetsErrorOnFailure() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }

        await sut.load(apiClient: client)

        XCTAssertNotNil(sut.error, "error should be set on 500 response")
        XCTAssertFalse(sut.isLoading, "isLoading should be false after load failure")
    }

    // MARK: - Test 4: Load clears error on retry

    func testLoadClearsErrorOnRetry() async {
        // First call: fail
        let failClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }
        await sut.load(apiClient: failClient)
        XCTAssertNotNil(sut.error, "error should be set after failure")

        // Second call: succeed
        let successClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), listBinsSuccessJSON)
        }
        await sut.load(apiClient: successClient)

        XCTAssertNil(sut.error, "error should be nil after successful retry")
        XCTAssertEqual(sut.bins.count, 2, "bins should be populated after retry")
    }

    // MARK: - Test 5: isLoading is false after completion

    func testLoadIsLoadingFalseAfterCompletion() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), listBinsSuccessJSON)
        }

        await sut.load(apiClient: client)

        XCTAssertFalse(sut.isLoading, "isLoading should be false after load completes")
    }

    // MARK: - Test 6: Preserves alphanumeric order returned by APIClient

    func testLoadPreservesAlphanumericOrder() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), listBinsSuccessJSON)
        }

        await sut.load(apiClient: client)

        // APIClient.listBins() already sorts alphanumerically.
        // The ViewModel preserves that order without re-sorting.
        XCTAssertEqual(sut.bins.count, 2, "Should have 2 bins")
        XCTAssertEqual(sut.bins[0].binId, "BIN-0001", "First bin should be BIN-0001")
        XCTAssertEqual(sut.bins[1].binId, "BIN-0002", "Second bin should be BIN-0002")
    }
}
