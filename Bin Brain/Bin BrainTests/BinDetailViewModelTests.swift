// BinDetailViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for BinDetailViewModel.swift.
// BinDetailView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in BinDetailViewModel.

import XCTest
@testable import Bin_Brain

// MARK: - BinDetailMockURLProtocol

/// A URLProtocol subclass that intercepts all requests for BinDetailViewModel tests.
///
/// Uses a distinct name to avoid symbol collisions with other mock protocols.
final class BinDetailMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = BinDetailMockURLProtocol.requestHandler else {
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

// MARK: - BinDetailViewModelTests

final class BinDetailViewModelTests: XCTestCase {

    var sut: BinDetailViewModel!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = BinDetailViewModel()
    }

    override func tearDown() async throws {
        BinDetailMockURLProtocol.requestHandler = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        BinDetailMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BinDetailMockURLProtocol.self]
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

    private var getBinSuccessJSON: Data {
        Data("""
        {
            "version": "1",
            "bin_id": "BIN-0001",
            "items": [
                {"item_id": 1, "name": "Widget", "category": "Hardware", "quantity": 5.0, "confidence": 0.92},
                {"item_id": 2, "name": "Bolt", "category": "Fasteners", "quantity": null, "confidence": 0.78}
            ],
            "photos": [{"photo_id": 42, "path": "/photos/42.jpg"}]
        }
        """.utf8)
    }

    private var upsertSuccessJSON: Data {
        Data("""
        {"version":"1","item_id":101,"fingerprint":"widget|hardware","name":"Widget","category":"Hardware"}
        """.utf8)
    }

    private var removeItemSuccessJSON: Data {
        Data("""
        {"removed":true}
        """.utf8)
    }

    private var updateItemSuccessJSON: Data {
        Data("""
        {"item_id":1,"bin_id":"BIN-0001","quantity":10.0,"confidence":0.95}
        """.utf8)
    }

    private var serverErrorJSON: Data {
        Data("""
        {"version":"1","error":{"code":"server_error","message":"Internal server error"}}
        """.utf8)
    }

    // MARK: - Test 1: Initial state

    func testInitialState() {
        XCTAssertNil(sut.bin, "bin should be nil on init")
        XCTAssertFalse(sut.isLoading, "isLoading should be false on init")
        XCTAssertNil(sut.error, "error should be nil on init")
    }

    // MARK: - Test 2: Load populates bin

    func testLoadPopulatesBin() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), getBinSuccessJSON)
        }

        await sut.load(binId: "BIN-0001", apiClient: client)

        XCTAssertNotNil(sut.bin, "bin should be populated after successful load")
        XCTAssertEqual(sut.bin?.binId, "BIN-0001", "bin id should match")
        XCTAssertEqual(sut.bin?.items.count, 2, "Should have 2 items")
        XCTAssertFalse(sut.isLoading, "isLoading should be false after load")
        XCTAssertNil(sut.error, "error should be nil after successful load")
    }

    // MARK: - Test 3: Load sets error on failure

    func testLoadSetsErrorOnFailure() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }

        await sut.load(binId: "BIN-0001", apiClient: client)

        XCTAssertNotNil(sut.error, "error should be set on 500 response")
        XCTAssertNil(sut.bin, "bin should remain nil after failure")
        XCTAssertFalse(sut.isLoading, "isLoading should be false after load failure")
    }

    // MARK: - Test 4: Load clears error on retry

    func testLoadClearsErrorOnRetry() async {
        // First call: fail
        let failClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }
        await sut.load(binId: "BIN-0001", apiClient: failClient)
        XCTAssertNotNil(sut.error, "error should be set after failure")

        // Second call: succeed
        let successClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), getBinSuccessJSON)
        }
        await sut.load(binId: "BIN-0001", apiClient: successClient)

        XCTAssertNil(sut.error, "error should be nil after successful retry")
        XCTAssertNotNil(sut.bin, "bin should be populated after retry")
    }

    // MARK: - Test 5: addItem calls upsert and reloads

    func testAddItemCallsUpsertAndReloads() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/items") == true {
                return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
            }
            // GET /bins/BIN-0001
            return (mockResponse(statusCode: 200, for: request), getBinSuccessJSON)
        }

        await sut.addItem(
            name: "Widget",
            category: "Hardware",
            quantity: 5.0,
            binId: "BIN-0001",
            apiClient: client
        )

        XCTAssertNotNil(sut.bin, "bin should be populated after addItem triggers reload")
    }

    // MARK: - Test 6: removeItem calls DELETE and reloads

    func testRemoveItemCallsDeleteAndReloads() async {
        let client = makeMockAPIClient { [self] request in
            if request.httpMethod == "DELETE" {
                return (mockResponse(statusCode: 200, for: request), removeItemSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), getBinSuccessJSON)
        }

        await sut.removeItem(itemId: 1, binId: "BIN-0001", apiClient: client)

        XCTAssertNotNil(sut.bin, "bin should be populated after removeItem triggers reload")
        XCTAssertNil(sut.error, "error should be nil after successful removeItem")
    }

    // MARK: - Test 7: removeItem sets error on failure

    func testRemoveItemSetsErrorOnFailure() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }

        await sut.removeItem(itemId: 1, binId: "BIN-0001", apiClient: client)

        XCTAssertNotNil(sut.error, "error should be set on failed removeItem")
    }

    // MARK: - Test 8: updateItem calls PATCH and reloads

    func testUpdateItemCallsPatchAndReloads() async {
        let client = makeMockAPIClient { [self] request in
            if request.httpMethod == "PATCH" {
                return (mockResponse(statusCode: 200, for: request), updateItemSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), getBinSuccessJSON)
        }

        await sut.updateItem(
            itemId: 1,
            quantity: 10.0,
            confidence: 0.95,
            binId: "BIN-0001",
            apiClient: client
        )

        XCTAssertNotNil(sut.bin, "bin should be populated after updateItem triggers reload")
        XCTAssertNil(sut.error, "error should be nil after successful updateItem")
    }

    // MARK: - Test 9: updateItem sets error on failure

    func testUpdateItemSetsErrorOnFailure() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }

        await sut.updateItem(
            itemId: 1,
            quantity: 10.0,
            confidence: nil,
            binId: "BIN-0001",
            apiClient: client
        )

        XCTAssertNotNil(sut.error, "error should be set on failed updateItem")
    }
}
