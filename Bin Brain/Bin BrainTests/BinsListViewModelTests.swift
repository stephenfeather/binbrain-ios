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

@MainActor
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

    // MARK: - Swift2_022 — Binless (UNASSIGNED sentinel) surfacing

    /// Server returns UNASSIGNED ordered by its default alphanumeric spot.
    /// The VM must pin it to index 0 regardless of that position so users
    /// can always find binless items at the top of the list.
    private var listBinsWithSentinelJSON: Data {
        Data("""
        {
            "version": "1",
            "bins": [
                {"bin_id": "BIN-0001", "item_count": 3, "photo_count": 2, "last_updated": "2026-02-25T20:00:00Z"},
                {"bin_id": "UNASSIGNED", "item_count": 0, "photo_count": 0, "last_updated": "2026-04-01T00:00:00Z"},
                {"bin_id": "BIN-0002", "item_count": 1, "photo_count": 1, "last_updated": "2026-02-24T10:00:00Z"}
            ]
        }
        """.utf8)
    }

    func testLoadPinsSentinelToTopRegardlessOfAlphanumericOrder() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), listBinsWithSentinelJSON)
        }

        await sut.load(apiClient: client)

        XCTAssertEqual(sut.bins.count, 3)
        XCTAssertEqual(sut.bins[0].binId, "UNASSIGNED",
                       "UNASSIGNED must be pinned first so Binless is always discoverable")
        XCTAssertEqual(sut.bins[1].binId, "BIN-0001",
                       "Non-sentinel bins retain APIClient's alphanumeric order")
        XCTAssertEqual(sut.bins[2].binId, "BIN-0002")
    }

    func testDisplayNameRemapsSentinelToBinless() {
        XCTAssertEqual(BinsListViewModel.displayName(for: "UNASSIGNED"), "Binless",
                       "The raw sentinel id must never be shown to the user")
        XCTAssertEqual(BinsListViewModel.displayName(for: "BIN-0042"), "BIN-0042",
                       "Regular bin ids pass through unchanged")
    }

    func testIsSentinelIdentifiesUnassignedOnly() {
        XCTAssertTrue(BinsListViewModel.isSentinel("UNASSIGNED"))
        XCTAssertFalse(BinsListViewModel.isSentinel("BIN-0001"))
        XCTAssertFalse(BinsListViewModel.isSentinel("unassigned"),
                       "Sentinel detection is case-sensitive — server id is UPPER-CASE")
    }

    // MARK: - Swift2_022 — deleteBin

    private var deleteBinSuccessJSON: Data {
        Data("""
        {"status":"deleted","bin_id":"BIN-0001","moved_item_count":3,"deleted_at":"2026-04-19T22:30:00Z"}
        """.utf8)
    }

    private var notFoundJSON: Data {
        Data("""
        {"version":"1","error":{"code":"not_found","message":"Bin not found"}}
        """.utf8)
    }

    private var cannotDeleteSentinelJSON: Data {
        Data("""
        {"version":"1","error":{"code":"cannot_delete_sentinel","message":"The UNASSIGNED bin cannot be deleted."}}
        """.utf8)
    }

    func testDeleteBinHappyPathSetsToastAndRefreshes() async {
        var callCount = 0
        let client = makeMockAPIClient { [self] request in
            callCount += 1
            if request.httpMethod == "DELETE" {
                return (mockResponse(statusCode: 200, for: request), deleteBinSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), listBinsSuccessJSON)
        }

        await sut.deleteBin(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(callCount, 2, "deleteBin must issue DELETE then reload via listBins")
        XCTAssertNotNil(sut.toastMessage, "Successful delete must surface a toast")
        XCTAssertTrue(sut.toastMessage?.contains("3") ?? false,
                      "Toast must cite moved_item_count so the user sees where items went")
        XCTAssertTrue(sut.toastMessage?.localizedCaseInsensitiveContains("binless") ?? false,
                      "Toast copy must use the word 'binless' not 'unassigned'")
    }

    /// Even though the UI removes the swipe affordance for UNASSIGNED, the VM
    /// must still reject a sentinel delete if one is ever invoked — defense
    /// in depth against a latent bug in the view layer.
    func testDeleteBinRejectsSentinelWithoutTouchingNetwork() async {
        var networkHit = false
        let client = makeMockAPIClient { [self] request in
            networkHit = true
            return (mockResponse(statusCode: 500, for: request), Data())
        }

        await sut.deleteBin(binId: "UNASSIGNED", apiClient: client)

        XCTAssertFalse(networkHit,
                       "Sentinel delete must short-circuit before any network call — matches the OpenAPI guidance that the UI should never make this call")
        XCTAssertNil(sut.toastMessage, "No toast on a refused sentinel delete")
    }

    func testDeleteBin404SetsBinNoLongerExistsBanner() async {
        let client = makeMockAPIClient { [self] request in
            if request.httpMethod == "DELETE" {
                return (mockResponse(statusCode: 404, for: request), notFoundJSON)
            }
            return (mockResponse(statusCode: 200, for: request), listBinsSuccessJSON)
        }

        await sut.deleteBin(binId: "BIN-MISSING", apiClient: client)

        XCTAssertEqual(sut.toastMessage, "Bin no longer exists",
                       "404 treated as idempotent success but banner tells the user the bin was already gone")
        XCTAssertEqual(sut.bins.count, 2, "List must be refreshed after 404")
    }

    func testDeleteBin400CannotDeleteSentinelSurfacesErrorMessage() async {
        let client = makeMockAPIClient { [self] request in
            if request.httpMethod == "DELETE" {
                return (mockResponse(statusCode: 400, for: request), cannotDeleteSentinelJSON)
            }
            return (mockResponse(statusCode: 200, for: request), listBinsSuccessJSON)
        }

        // Force past the VM's own sentinel guard by passing a non-sentinel id
        // (the server-side rejection reflects a latent UI bug per the prompt).
        await sut.deleteBin(binId: "BIN-SOMEHOW", apiClient: client)

        XCTAssertNotNil(sut.error,
                        "Server 400 cannot_delete_sentinel must surface so we notice the UI guard bug")
        XCTAssertTrue(sut.error?.contains("UNASSIGNED") ?? false,
                      "Error message should include the server's explanation")
    }
}
