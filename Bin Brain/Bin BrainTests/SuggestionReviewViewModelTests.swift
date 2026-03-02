// SuggestionReviewViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for SuggestionReviewViewModel.swift.
// SuggestionReviewView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in SuggestionReviewViewModel.

import XCTest
@testable import Bin_Brain

// MARK: - SuggestionReviewMockURLProtocol

/// A URLProtocol subclass that intercepts all requests for SuggestionReviewViewModel tests.
///
/// Uses a distinct name from `MockURLProtocol` and `AnalysisMockURLProtocol`
/// to avoid link-time symbol collisions with other test files.
final class SuggestionReviewMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = SuggestionReviewMockURLProtocol.requestHandler else {
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

// MARK: - URLRequest body helper

private extension URLRequest {
    /// Returns the request body as `Data`, reading from `httpBody` or `httpBodyStream`.
    ///
    /// `URLSession` converts `httpBody` to a stream before passing the request to
    /// `URLProtocol`, so both sources must be checked.
    var bodyData: Data? {
        if let data = httpBody { return data }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }
}

// MARK: - SuggestionReviewViewModelTests

final class SuggestionReviewViewModelTests: XCTestCase {

    var sut: SuggestionReviewViewModel!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = SuggestionReviewViewModel()
    }

    override func tearDown() async throws {
        SuggestionReviewMockURLProtocol.requestHandler = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        SuggestionReviewMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SuggestionReviewMockURLProtocol.self]
        return APIClient(session: URLSession(configuration: config))
    }

    private func makeSuggestions() throws -> [SuggestionItem] {
        let json = Data("""
        [
            {"item_id": null, "name": "Widget", "category": "Hardware", "confidence": 0.92, "bins": ["BIN-0001"]},
            {"item_id": 5, "name": "Bolt", "category": "Fasteners", "confidence": 0.78, "bins": ["BIN-0001"]}
        ]
        """.utf8)
        return try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)
    }

    private var upsertSuccessJSON: Data {
        Data("""
        {"version":"1","item_id":101,"fingerprint":"widget|hardware","name":"Widget","category":"Hardware"}
        """.utf8)
    }

    private var serverErrorJSON: Data {
        Data("""
        {"version":"1","error":{"code":"server_error","message":"Internal server error"}}
        """.utf8)
    }

    private func mockResponse(statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: - Test 1: Initial state

    func testInitialState() {
        XCTAssertTrue(sut.editableSuggestions.isEmpty, "editableSuggestions should be empty on init")
        XCTAssertFalse(sut.isConfirming, "isConfirming should be false on init")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty on init")
    }

    // MARK: - Test 2: loadSuggestions populates editableSuggestions

    func testLoadSuggestions() throws {
        let suggestions = try makeSuggestions()

        sut.loadSuggestions(suggestions)

        XCTAssertEqual(sut.editableSuggestions.count, 2, "Should have 2 editable suggestions")

        // First suggestion
        XCTAssertEqual(sut.editableSuggestions[0].id, 0)
        XCTAssertTrue(sut.editableSuggestions[0].included, "All items start included")
        XCTAssertEqual(sut.editableSuggestions[0].editedName, "Widget")
        XCTAssertEqual(sut.editableSuggestions[0].editedCategory, "Hardware")
        XCTAssertEqual(sut.editableSuggestions[0].editedQuantity, "")
        XCTAssertEqual(sut.editableSuggestions[0].confidence, 0.92, accuracy: 0.001)

        // Second suggestion
        XCTAssertEqual(sut.editableSuggestions[1].id, 1)
        XCTAssertTrue(sut.editableSuggestions[1].included, "All items start included")
        XCTAssertEqual(sut.editableSuggestions[1].editedName, "Bolt")
        XCTAssertEqual(sut.editableSuggestions[1].editedCategory, "Fasteners")
        XCTAssertEqual(sut.editableSuggestions[1].editedQuantity, "")
        XCTAssertEqual(sut.editableSuggestions[1].confidence, 0.78, accuracy: 0.001)

        // failedIndices should be cleared
        XCTAssertTrue(sut.failedIndices.isEmpty, "loadSuggestions should clear failedIndices")
    }

    // MARK: - Test 3: confirm upserts all included suggestions

    func testConfirmUpsertsAllIncluded() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        var callCount = 0
        let client = makeMockAPIClient { [self] request in
            callCount += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after confirm completes")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty after successful confirm")
        XCTAssertEqual(callCount, 2, "Should have made 2 upsert calls (one per included suggestion)")
    }

    // MARK: - Test 4: confirm skips excluded suggestions

    func testConfirmSkipsExcludedSuggestions() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        sut.editableSuggestions[1].included = false

        var callCount = 0
        let client = makeMockAPIClient { [self] request in
            callCount += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(callCount, 1, "Should have made only 1 upsert call (excluded suggestion skipped)")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty after successful confirm")
    }

    // MARK: - Test 5: confirm stops on first failure

    func testConfirmStopsOnFirstFailure() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        var callCount = 0
        let client = makeMockAPIClient { [self] request in
            callCount += 1
            // First call fails with 500
            return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(callCount, 1, "Should stop after first failure")
        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after failure")
        XCTAssertEqual(sut.failedIndices.count, 2, "failedIndices should contain failed + remaining")
        XCTAssertTrue(sut.failedIndices.contains(0), "failedIndices should contain index 0 (failed)")
        XCTAssertTrue(sut.failedIndices.contains(1), "failedIndices should contain index 1 (not attempted)")
    }

    // MARK: - Test 6: retryRemaining succeeds after partial failure

    func testRetryRemainingSucceeds() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        // First confirm: fail on first call to set failedIndices
        var attempt = 0
        let failFirstClient = makeMockAPIClient { [self] request in
            attempt += 1
            if attempt == 1 {
                return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: failFirstClient)

        // Verify partial failure state
        XCTAssertFalse(sut.failedIndices.isEmpty, "failedIndices should be non-empty after partial failure")

        // Now retry with a client that always succeeds
        let succeedClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.retryRemaining(binId: "BIN-0001", apiClient: succeedClient)

        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty after successful retry")
        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after retry completes")
    }

    // MARK: - Test 7: confirm with all excluded is a no-op success

    func testConfirmWithAllExcluded() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        sut.editableSuggestions[0].included = false
        sut.editableSuggestions[1].included = false

        var callCount = 0
        let client = makeMockAPIClient { [self] request in
            callCount += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(callCount, 0, "No upsert calls should be made when all suggestions are excluded")
        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after confirm with all excluded")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty (nothing to fail)")
    }

    // MARK: - Test 8: edited fields are sent to API

    func testEditableFieldsUpdatable() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        // Edit the first suggestion's name
        sut.editableSuggestions[0].editedName = "Renamed"
        // Exclude the second so we only get one call
        sut.editableSuggestions[1].included = false

        var capturedBody: String?
        let client = makeMockAPIClient { [self] request in
            if let data = request.bodyData {
                capturedBody = String(data: data, encoding: .utf8)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertNotNil(capturedBody, "Request body should not be nil")
        XCTAssertTrue(
            capturedBody?.contains("Renamed") == true,
            "Request body should contain the edited name 'Renamed'"
        )
    }

    // MARK: - Test 9: loadSuggestions with empty array shows empty state

    func testLoadEmptySuggestionsKeepsEmptyState() {
        sut.loadSuggestions([])

        XCTAssertTrue(sut.editableSuggestions.isEmpty, "Should have no editable suggestions")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty")
    }

    // MARK: - Test 10: confirm with empty suggestions is a no-op

    func testConfirmWithEmptySuggestionsIsNoOp() async {
        sut.loadSuggestions([])

        var callCount = 0
        let client = makeMockAPIClient { [self] request in
            callCount += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(callCount, 0, "No API calls should be made with empty suggestions")
        XCTAssertFalse(sut.isConfirming, "isConfirming should be false")
    }
}
