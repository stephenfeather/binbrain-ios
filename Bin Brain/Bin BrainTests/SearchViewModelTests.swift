// SearchViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for SearchViewModel.swift.
// SearchView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in SearchViewModel.

import XCTest
@testable import Bin_Brain

// MARK: - SearchMockURLProtocol

/// A URLProtocol subclass that intercepts all requests for SearchViewModel tests.
///
/// Uses a distinct name to avoid symbol collisions with other mock protocols.
final class SearchMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = SearchMockURLProtocol.requestHandler else {
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

// MARK: - SearchViewModelTests

final class SearchViewModelTests: XCTestCase {

    var sut: SearchViewModel!
    var testDefaults: UserDefaults!
    var suiteName: String!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SearchViewModelTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        sut = SearchViewModel(defaults: testDefaults)
    }

    override func tearDown() async throws {
        SearchMockURLProtocol.requestHandler = nil
        testDefaults.removePersistentDomain(forName: suiteName)
        sut = nil
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        SearchMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchMockURLProtocol.self]
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

    // MARK: - JSON Fixtures

    private var searchSuccessJSON: Data {
        Data("""
        {
            "version": "1",
            "q": "widget",
            "limit": 10,
            "offset": 0,
            "min_score": null,
            "results": [
                {"item_id": 1, "name": "Widget", "category": "Hardware", "upc": null, "score": 0.9, "bins": ["BIN-0001"]},
                {"item_id": 2, "name": "Mini Widget", "category": "Hardware", "upc": null, "score": 0.7, "bins": ["BIN-0001", "BIN-0002"]}
            ]
        }
        """.utf8)
    }

    private var searchEmptyJSON: Data {
        Data("""
        {"version": "1", "q": "xyzzy", "limit": 10, "offset": 0, "min_score": null, "results": []}
        """.utf8)
    }

    private var serverErrorJSON: Data {
        Data("""
        {"version":"1","error":{"code":"server_error","message":"Internal server error"}}
        """.utf8)
    }

    private var searchScoreJSON: Data {
        Data("""
        {
            "version": "1",
            "q": "widget",
            "limit": 10,
            "offset": 0,
            "min_score": null,
            "results": [
                {"item_id": 1, "name": "Widget", "category": "Hardware", "upc": null, "score": 0.8, "bins": ["BIN-0001"]}
            ]
        }
        """.utf8)
    }

    // MARK: - Test 1: Initial state

    func testInitialState() {
        XCTAssertTrue(sut.query.isEmpty, "query should be empty on init")
        XCTAssertTrue(sut.results.isEmpty, "results should be empty on init")
        XCTAssertFalse(sut.isSearching, "isSearching should be false on init")
    }

    // MARK: - Test 2: performSearch returns results

    func testPerformSearchReturnsResults() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)

        XCTAssertEqual(sut.results.count, 2, "Should have 2 results after successful search")
        XCTAssertFalse(sut.isSearching, "isSearching should be false after search completes")
    }

    // MARK: - Test 3: performSearch clears results on empty query

    func testPerformSearchClearsResultsOnEmptyQuery() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)
        XCTAssertEqual(sut.results.count, 2, "Should have 2 results after first search")

        sut.query = ""
        await sut.performSearch(apiClient: client)

        XCTAssertTrue(sut.results.isEmpty, "results should be empty when query is empty")
    }

    // MARK: - Test 4: performSearch surfaces error

    func testPerformSearchSetsErrorOnFailure() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)

        XCTAssertTrue(sut.results.isEmpty, "results should be empty on error")
        XCTAssertFalse(sut.isSearching, "isSearching should be false after error")
        XCTAssertNotNil(sut.error, "error should be populated on failure")
    }

    func testPerformSearchClearsErrorOnSuccess() async {
        let failClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: failClient)
        XCTAssertNotNil(sut.error, "error should be set after failure")

        let successClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        await sut.performSearch(apiClient: successClient)

        XCTAssertNil(sut.error, "error should be cleared on successful search")
    }

    // MARK: - Test 5: Score calculation

    func testScoreCalculation() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), searchScoreJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)

        XCTAssertEqual(sut.results.count, 1, "Should have 1 result")
        XCTAssertEqual(sut.results[0].score, 0.8, accuracy: 0.0001,
                       "Score should match server-provided value")
    }

    // MARK: - Test 6: scheduleSearch clears results immediately on empty query

    func testScheduleSearchClearsResultsImmediatelyOnEmptyQuery() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)
        XCTAssertEqual(sut.results.count, 2, "Should have 2 results after first search")

        sut.query = ""
        sut.scheduleSearch(apiClient: client)

        XCTAssertTrue(sut.results.isEmpty,
                      "results should be cleared immediately when query becomes empty")
    }

    // MARK: - Test 7: performSearch passes query in URL

    func testPerformSearchPassesQueryInURL() async {
        var capturedURL: URL?
        let client = makeMockAPIClient { [self] request in
            capturedURL = request.url
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)

        XCTAssertTrue(capturedURL?.absoluteString.contains("q=widget") == true,
                      "URL should contain q=widget")
    }

    // MARK: - Test 8: explicit threshold of 0 is passed to the API (Issue #7)

    func testPerformSearchPassesExplicitZeroThreshold() async {
        testDefaults.set(0.0, forKey: "similarityThreshold")
        // Re-create sut so it reads the just-persisted value at call time.
        sut = SearchViewModel(defaults: testDefaults)

        var capturedURL: URL?
        let client = makeMockAPIClient { [self] request in
            capturedURL = request.url
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)

        let absolute = capturedURL?.absoluteString ?? ""
        XCTAssertTrue(absolute.contains("min_score=0"),
                      "When the user explicitly sets threshold to 0, min_score=0 must be sent to the server. Got: \(absolute)")
    }

    // MARK: - Test 9: unset threshold omits min_score (Issue #7)

    func testPerformSearchOmitsMinScoreWhenUnset() async {
        // testDefaults has no similarityThreshold key
        var capturedURL: URL?
        let client = makeMockAPIClient { [self] request in
            capturedURL = request.url
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)

        let absolute = capturedURL?.absoluteString ?? ""
        XCTAssertFalse(absolute.contains("min_score"),
                       "When threshold is unset, min_score should be omitted from the request. Got: \(absolute)")
    }

    // MARK: - Test 10: user-set threshold is passed through (Issue #7)

    func testPerformSearchPassesUserThreshold() async {
        testDefaults.set(0.7, forKey: "similarityThreshold")
        sut = SearchViewModel(defaults: testDefaults)

        var capturedURL: URL?
        let client = makeMockAPIClient { [self] request in
            capturedURL = request.url
            return (mockResponse(statusCode: 200, for: request), searchSuccessJSON)
        }
        sut.query = "widget"
        await sut.performSearch(apiClient: client)

        let absolute = capturedURL?.absoluteString ?? ""
        XCTAssertTrue(absolute.contains("min_score=0.7"),
                      "User-set threshold should be forwarded as min_score. Got: \(absolute)")
    }

    // MARK: - Test 11: navigation disabled when bins empty (Issue #5)

    func testShouldEnableNavigationReturnsFalseWhenBinsEmpty() {
        let result = SearchResultItem(
            itemId: 42, name: "Orphan", category: nil, upc: nil, score: 0.9, bins: []
        )
        XCTAssertFalse(SearchViewModel.shouldEnableNavigation(for: result),
                       "Navigation must be disabled when result.bins is empty")
    }

    // MARK: - Test 12: navigation enabled when bins present (Issue #5)

    func testShouldEnableNavigationReturnsTrueWhenBinsPresent() {
        let result = SearchResultItem(
            itemId: 42, name: "Widget", category: nil, upc: nil, score: 0.9, bins: ["BIN-0001"]
        )
        XCTAssertTrue(SearchViewModel.shouldEnableNavigation(for: result),
                      "Navigation must be enabled when result.bins has at least one bin")
    }
}
