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
        UserDefaults.standard.set("test-key", forKey: "apiKey")
        sut = SuggestionReviewViewModel()
    }

    override func tearDown() async throws {
        SuggestionReviewMockURLProtocol.requestHandler = nil
        sut = nil
        UserDefaults.standard.removeObject(forKey: "apiKey")
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

    private var confirmClassSuccessJSON: Data {
        Data("""
        {"version":"1","class_name":"Widget","added":true,"active_class_count":47,"reload_triggered":true}
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

        var upsertCount = 0
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            upsertCount += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after confirm completes")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty after successful confirm")
        XCTAssertEqual(upsertCount, 2, "Should have made 2 upsert calls (one per included suggestion)")
    }

    // MARK: - Test 4: confirm skips excluded suggestions

    func testConfirmSkipsExcludedSuggestions() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        sut.editableSuggestions[1].included = false

        var upsertCount = 0
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            upsertCount += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(upsertCount, 1, "Should have made only 1 upsert call (excluded suggestion skipped)")
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

    // MARK: - Test 9: loadSuggestions prefers match name/category

    func testLoadSuggestionsUsesMatchNameWhenAvailable() throws {
        let json = Data("""
        [
            {
                "item_id": null,
                "name": "hex nut",
                "category": "hardware",
                "confidence": 0.61,
                "bins": [],
                "match": {
                    "item_id": 42,
                    "name": "Hex Nut M3",
                    "category": "Fasteners",
                    "score": 0.87,
                    "bins": ["B-10"]
                }
            },
            {
                "item_id": null,
                "name": "mystery part",
                "category": null,
                "confidence": 0.3,
                "bins": [],
                "match": null
            }
        ]
        """.utf8)
        let suggestions = try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)

        sut.loadSuggestions(suggestions)

        // First: matched — should use catalogue name/category
        XCTAssertEqual(sut.editableSuggestions[0].editedName, "Hex Nut M3")
        XCTAssertEqual(sut.editableSuggestions[0].editedCategory, "Fasteners")
        XCTAssertEqual(sut.editableSuggestions[0].visionName, "hex nut")
        XCTAssertTrue(sut.editableSuggestions[0].isMatched)
        let matchScore = try XCTUnwrap(sut.editableSuggestions[0].match?.score)
        XCTAssertEqual(matchScore, 0.87, accuracy: 1e-10)

        // Second: no match — should use vision name, empty category
        XCTAssertEqual(sut.editableSuggestions[1].editedName, "mystery part")
        XCTAssertEqual(sut.editableSuggestions[1].editedCategory, "")
        XCTAssertEqual(sut.editableSuggestions[1].visionName, "mystery part")
        XCTAssertFalse(sut.editableSuggestions[1].isMatched)
        XCTAssertNil(sut.editableSuggestions[1].match)
    }

    // MARK: - Test 10: loadSuggestions without match preserves vision data

    func testLoadSuggestionsWithoutMatchPreservesVisionName() throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        XCTAssertEqual(sut.editableSuggestions[0].visionName, "Widget")
        XCTAssertNil(sut.editableSuggestions[0].match)
        XCTAssertFalse(sut.editableSuggestions[0].isMatched)
    }

    // MARK: - Test 11: loadSuggestions with empty array shows empty state

    func testLoadEmptySuggestionsKeepsEmptyState() {
        sut.loadSuggestions([])

        XCTAssertTrue(sut.editableSuggestions.isEmpty, "Should have no editable suggestions")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty")
    }

    // MARK: - Test 12: confirm with empty suggestions is a no-op

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

    // MARK: - Test 13: loadSuggestions sets teach to true by default

    func testLoadSuggestionsDefaultsTeachToTrue() throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        XCTAssertTrue(sut.editableSuggestions[0].teach, "teach should default to true")
        XCTAssertTrue(sut.editableSuggestions[1].teach, "teach should default to true")
    }

    // MARK: - Test 14: confirm calls confirmClass for taught items

    func testConfirmCallsConfirmClassForTaughtItems() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        // Disable teach on second item
        sut.editableSuggestions[1].teach = false

        var requestPaths: [String] = []
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            requestPaths.append(path)
            if path.contains("/classes/confirm") {
                let json = Data("""
                {"version":"1","class_name":"Widget","added":true,"active_class_count":47,"reload_triggered":true}
                """.utf8)
                return (mockResponse(statusCode: 200, for: request), json)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        // 2 upsert calls + 1 confirmClass call (only first item has teach=true)
        let confirmCalls = requestPaths.filter { $0.contains("/classes/confirm") }
        XCTAssertEqual(confirmCalls.count, 1, "Should call confirmClass once for the taught item")
        let upsertCalls = requestPaths.filter { $0.contains("/items") }
        XCTAssertEqual(upsertCalls.count, 2, "Should call upsert for both included items")
    }

    // MARK: - Test 15: confirm does not call confirmClass when teach is false for all

    func testConfirmSkipsConfirmClassWhenAllTeachDisabled() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        sut.editableSuggestions[0].teach = false
        sut.editableSuggestions[1].teach = false

        var requestPaths: [String] = []
        let client = makeMockAPIClient { [self] request in
            requestPaths.append(request.url?.path ?? "")
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        let confirmCalls = requestPaths.filter { $0.contains("/classes/confirm") }
        XCTAssertEqual(confirmCalls.count, 0, "Should not call confirmClass when all teach=false")
    }

    // MARK: - Test 16: confirmClass failure does not block confirm completion

    func testConfirmClassFailureDoesNotBlockConfirm() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after confirm completes")
        XCTAssertTrue(sut.failedIndices.isEmpty, "Upserts succeeded, confirmClass failures are fire-and-forget")
    }

    // MARK: - Test 17: teachFailureCount tracks confirmClass failures

    func testTeachFailureCountIncrementsOnClassFailures() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(sut.teachFailureCount, 2,
                       "teachFailureCount should equal the number of failed confirmClass calls")
    }

    // MARK: - Test 18: teachFailureCount stays zero on success

    func testTeachFailureCountZeroWhenAllClassesSucceed() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(sut.teachFailureCount, 0,
                       "teachFailureCount should be 0 when all confirmClass calls succeed")
    }

    // MARK: - Test 19: teachFailureCount resets at start of confirm

    func testTeachFailureCountResetsBetweenConfirms() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        // First confirm: teach failures
        let failClient = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }
        await sut.confirm(binId: "BIN-0001", apiClient: failClient)
        XCTAssertEqual(sut.teachFailureCount, 2, "precondition: teach failures recorded")

        // Second confirm: all succeed
        let okClient = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }
        await sut.confirm(binId: "BIN-0001", apiClient: okClient)

        XCTAssertEqual(sut.teachFailureCount, 0,
                       "teachFailureCount should reset at the start of each confirm")
    }
}
