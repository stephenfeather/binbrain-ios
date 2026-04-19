// SuggestionReviewViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for SuggestionReviewViewModel.swift.
// SuggestionReviewView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in SuggestionReviewViewModel.

import XCTest
import UIKit
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

@MainActor
final class SuggestionReviewViewModelTests: XCTestCase {

    var sut: SuggestionReviewViewModel!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = SuggestionReviewViewModel()
        // Legacy default-on UX is the rollback target for Swift2_020. These
        // pre-existing tests assert the legacy semantics (rows arrive
        // included == true). Three-state behavior is covered separately in
        // SuggestionReviewThreeStateTests.swift.
        sut.threeStateEnabled = false
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
        return APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-key"])
        )
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

    private var associateSuccessJSON: Data {
        Data("""
        {"ok":true,"bin_id":"BIN-0001","item_id":101}
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
        var associateCount = 0
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                associateCount += 1
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            upsertCount += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after confirm completes")
        XCTAssertTrue(sut.failedIndices.isEmpty, "failedIndices should be empty after successful confirm")
        XCTAssertEqual(upsertCount, 2, "Should have made 2 upsert calls (one per included suggestion)")
        XCTAssertEqual(associateCount, 2, "Should have made 2 associate calls (one per upsert)")
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
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
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
            let path = request.url?.path ?? ""
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: failFirstClient)

        // Verify partial failure state
        XCTAssertFalse(sut.failedIndices.isEmpty, "failedIndices should be non-empty after partial failure")

        // Now retry with a client that always succeeds
        let succeedClient = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
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

        // Finding #16 — before confirm is even invoked, the view must gate
        // the button so the problematic all-excluded path can't be reached.
        XCTAssertFalse(sut.canConfirm,
                       "canConfirm must be false when every suggestion is excluded — View binds .disabled to this")

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

    func testCanConfirmTrueWhenAtLeastOneIncluded() throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        // Default state loads with everything included.
        XCTAssertTrue(sut.canConfirm, "canConfirm must be true with at least one included")

        sut.editableSuggestions[0].included = false
        XCTAssertTrue(sut.canConfirm, "still true while any row is included")

        sut.editableSuggestions[1].included = false
        XCTAssertFalse(sut.canConfirm, "flips false the moment the last included row toggles off")
    }

    func testCanConfirmFalseOnEmptyState() {
        sut.loadSuggestions([])
        XCTAssertFalse(sut.canConfirm, "empty list must not allow confirm")
    }

    /// Finding #21 — when the user excludes every suggestion (common when the
    /// on-device classifier returns garbage, e.g. pencil-on-carpet top-K), the
    /// primary action in `SuggestionReviewView` must be Dismiss, not Confirm.
    /// At the VM level the invariant is: `canConfirm == false` AND calling
    /// `confirm()` must NOT hit the server. The View binds the Dismiss button
    /// directly to `onDone()`, which is a closure-level assertion outside the
    /// VM's surface; this test covers the two VM-side guarantees.
    func testAllExcludedPrimaryPathDoesNotCallAPI() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        for idx in sut.editableSuggestions.indices {
            sut.editableSuggestions[idx].included = false
        }

        XCTAssertFalse(sut.canConfirm,
                       "precondition: with everything excluded canConfirm must be false so the View renders Dismiss")

        var apiCalls = 0
        let client = makeMockAPIClient { [self] request in
            apiCalls += 1
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        // Even if a caller invoked confirm() directly in this state, no
        // network I/O must fire — Dismiss is the only correct forward action.
        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(apiCalls, 0,
                       "all-excluded confirm must be a no-op; Dismiss -> onDone is the Views primary action")
        XCTAssertFalse(sut.isConfirming, "no hanging in-flight state")
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
            let path = request.url?.path ?? ""
            // Only capture the /items body — /associate bodies overwrite and
            // would mask the assertion about the edited name.
            if path == "/items", let data = request.bodyData {
                capturedBody = String(data: data, encoding: .utf8)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
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
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        // 2 upsert calls + 2 associate calls + 1 confirmClass call (only first item has teach=true)
        let confirmCalls = requestPaths.filter { $0.contains("/classes/confirm") }
        XCTAssertEqual(confirmCalls.count, 1, "Should call confirmClass once for the taught item")
        let upsertCalls = requestPaths.filter { $0 == "/items" }
        XCTAssertEqual(upsertCalls.count, 2, "Should call upsert for both included items")
        let associateCalls = requestPaths.filter { $0.hasSuffix("/associate") }
        XCTAssertEqual(associateCalls.count, 2, "Should call associate for each upsert")
    }

    // MARK: - Test 15: confirm does not call confirmClass when teach is false for all

    func testConfirmSkipsConfirmClassWhenAllTeachDisabled() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        sut.editableSuggestions[0].teach = false
        sut.editableSuggestions[1].teach = false

        var requestPaths: [String] = []
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            requestPaths.append(path)
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
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
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
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
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
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
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
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
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
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

    // MARK: - Test 20: Finding #6 — /items 200 + /associate 200 → success

    func testConfirmItemsAndAssociateBothSucceed() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        var itemsCount = 0
        var associateCount = 0
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                associateCount += 1
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            if path == "/items" {
                itemsCount += 1
                return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(itemsCount, 2, "Should POST /items once per included suggestion")
        XCTAssertEqual(associateCount, 2, "Should POST /associate once per successful /items")
        XCTAssertTrue(sut.failedIndices.isEmpty, "Pair succeeded — no failed indices")
    }

    // MARK: - Test 21: Finding #6 — /items 200 + /associate 500 → index marked failed

    func testConfirmAssociateFailureMarksIndexFailed() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/associate") {
                // /associate fails on the first call — this makes the pair fail
                // and halts the loop before the second index is attempted.
                return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertFalse(sut.isConfirming, "isConfirming should be false after failure")
        XCTAssertTrue(sut.failedIndices.contains(0),
                      "Index 0 should be marked failed when its /associate fails")
        XCTAssertTrue(sut.failedIndices.contains(1),
                      "Index 1 should be marked failed (not attempted)")
    }

    // MARK: - Test 22: Finding #6 — retryRemaining re-runs both /items and /associate

    func testRetryRemainingReRunsBothCalls() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        // Seed failedIndices = [0, 1] via an /associate failure on the first call.
        let seedClient = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 500, for: request), serverErrorJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }
        await sut.confirm(binId: "BIN-0001", apiClient: seedClient)
        XCTAssertEqual(Set(sut.failedIndices), Set([0, 1]),
                       "precondition: both indices should be queued for retry")

        // Retry: both /items and /associate should be re-issued for each index.
        var retryItems = 0
        var retryAssociate = 0
        let retryClient = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path == "/items" {
                retryItems += 1
                return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                retryAssociate += 1
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.retryRemaining(binId: "BIN-0001", apiClient: retryClient)

        XCTAssertEqual(retryItems, 2, "retry should re-issue /items for both queued indices")
        XCTAssertEqual(retryAssociate, 2, "retry should re-issue /associate for both queued indices")
        XCTAssertTrue(sut.failedIndices.isEmpty, "all retried pairs succeeded")
    }

    // MARK: - Swift2_005 Step 2: photoData

    func testPhotoDataIsNilByDefault() {
        XCTAssertNil(sut.photoData, "photoData must start nil on a fresh SuggestionReviewViewModel")
    }

    func testPhotoDataCanBeSetAndRead() {
        let data = Data("fake-jpeg-bytes".utf8)
        sut.photoData = data
        XCTAssertEqual(sut.photoData, data,
                       "photoData must retain the value that was assigned")
    }

    // MARK: - Swift2_012: binId on the ViewModel (durable through cataloging flow)

    func testBinIdIsEmptyByDefault() {
        XCTAssertEqual(sut.binId, "",
                       "binId must default to empty string on a fresh SuggestionReviewViewModel (Swift2_012)")
    }

    func testBinIdCanBeSetAndRead() {
        sut.binId = "BIN-0003"
        XCTAssertEqual(sut.binId, "BIN-0003",
                       "binId must retain the value assigned by the parent cataloging flow")
    }

    /// Regression guard for Swift2_012. The VM now owns binId so Confirm reads
    /// from a stable source instead of an ephemeral view-layer @State. This
    /// test simulates the fixed call pattern — parent assigns VM.binId
    /// alongside VM.photoData at ingest time, and Confirm later reads from
    /// the VM rather than from a parent-view property.
    func testConfirmReadsBinIdFromViewModel() async throws {
        sut.binId = "BIN-0003"
        sut.photoData = Data("jpeg-bytes".utf8)
        sut.loadSuggestions(try makeSuggestions())

        var receivedBinIds: [String] = []
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                if let body = request.bodyData,
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let binId = obj["bin_id"] as? String {
                    receivedBinIds.append(binId)
                }
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            // /items upsert — capture its bin_id too for symmetry.
            if let body = request.bodyData,
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let binId = obj["bin_id"] as? String {
                receivedBinIds.append(binId)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        // Fixed call pattern: SuggestionReviewView's Confirm button now does
        // `viewModel.confirm(binId: viewModel.binId, ...)` — reading from VM,
        // not from a parent-view property. Simulate that here.
        await sut.confirm(binId: sut.binId, apiClient: client)

        XCTAssertTrue(sut.failedIndices.isEmpty,
                      "Valid VM-held binId must drive a successful confirm; got failedIndices=\(sut.failedIndices)")
        XCTAssertFalse(receivedBinIds.isEmpty,
                       "Server must receive at least one /items or /associate request carrying bin_id")
        XCTAssertTrue(receivedBinIds.allSatisfy { $0 == "BIN-0003" },
                      "All requests must carry the VM-held binId 'BIN-0003'; got \(receivedBinIds)")
    }

    // MARK: - Swift2_005 Step 4: shouldShowPhoto

    func testShouldShowPhotoReturnsFalseForNil() {
        XCTAssertFalse(shouldShowPhoto(nil),
                       "shouldShowPhoto must return false when data is nil")
    }

    func testShouldShowPhotoReturnsFalseForNonImageData() {
        XCTAssertFalse(shouldShowPhoto(Data("not-a-jpeg".utf8)),
                       "shouldShowPhoto must return false for non-decodable data")
    }

    func testShouldShowPhotoReturnsTrueForValidJPEG() throws {
        let jpeg = try XCTUnwrap(makeMinimalJPEG(), "failed to synthesize test JPEG")
        XCTAssertTrue(shouldShowPhoto(jpeg),
                      "shouldShowPhoto must return true for valid JPEG bytes")
    }

    /// Builds a minimal valid 1×1 JPEG.
    private func makeMinimalJPEG() -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }

    // MARK: - Test 20: bbox passthrough from SuggestionItem → EditableSuggestion

    func testLoadSuggestionsPassesThroughBbox() throws {
        let json = Data("""
        [
            {
                "item_id": null,
                "name": "Widget",
                "category": "Hardware",
                "confidence": 0.9,
                "bins": [],
                "bbox": [0.1, 0.2, 0.8, 0.9]
            },
            {
                "item_id": null,
                "name": "Bolt",
                "category": "Fasteners",
                "confidence": 0.7,
                "bins": []
            }
        ]
        """.utf8)
        let suggestions = try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)

        sut.loadSuggestions(suggestions)

        let coords = try XCTUnwrap(sut.editableSuggestions[0].bbox, "bbox with 4 coords should pass through")
        XCTAssertEqual(coords.count, 4)
        XCTAssertEqual(coords[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(coords[1], 0.2, accuracy: 0.001)
        XCTAssertEqual(coords[2], 0.8, accuracy: 0.001)
        XCTAssertEqual(coords[3], 0.9, accuracy: 0.001)
        XCTAssertNil(sut.editableSuggestions[1].bbox, "Absent bbox should decode as nil")
    }

    // MARK: - Test 21: malformed bbox (wrong element count) is decoded and handled safely

    func testLoadSuggestionsToleratesMalformedBbox() throws {
        let json = Data("""
        [
            {
                "item_id": null,
                "name": "Widget",
                "category": null,
                "confidence": 0.8,
                "bins": [],
                "bbox": [0.1, 0.2]
            }
        ]
        """.utf8)
        // Decoding must not throw — [Float] accepts any-length array.
        let suggestions = try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)
        XCTAssertEqual(suggestions[0].bbox?.count, 2, "Short bbox should decode as-is, not nil")

        // loadSuggestions passes it through; bboxRect guards on count==4 (visual concern only).
        sut.loadSuggestions(suggestions)
        XCTAssertEqual(sut.editableSuggestions[0].bbox?.count, 2,
                       "Malformed bbox passes through loadSuggestions without crashing")
    }

    // MARK: - Swift2_009/010: async pinnedImage decode
    //
    // These tests assert the contract established by the pre-mortemed plan at
    // thoughts/shared/plans/2026-04-17-uiimage-decode-to-viewmodel.md:
    //   • decode runs off the main thread
    //   • pinnedImage is populated after valid photoData
    //   • malformed bytes leave pinnedImage nil (no crash)
    //   • setting photoData = nil clears pinnedImage
    //   • rapid photoData updates settle to the last value (generation guard)
    //
    // Synchronization strategy: `await sut.decodeTask?.value` acts as a hard
    // barrier — the task body awaits `publish(image:generation:)` on the main
    // actor, so when the task's value is reached, the main-actor publish has
    // already run. No fixed sleeps; safe under parallel simulator clones.

    /// Thread-safe box for capturing a Bool across actor boundaries in tests.
    private final class ThreadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Bool
        init(_ initial: Bool) { _value = initial }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    /// Builds a 2×2 solid-color JPEG with a known RGB marker for pixel-sampling tests.
    /// JPEG encoding is lossy, so callers compare with channel inequalities, not equality.
    private func makeSolidColorJPEG(r: UInt8, g: UInt8, b: UInt8) -> Data? {
        let width = 2, height = 2
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(r)
            pixels.append(g)
            pixels.append(b)
            pixels.append(255)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)
    }

    /// Reads pixel (x, y) from a CGImage by blitting into a 1×1 RGBA8 context.
    private func readPixel(cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    // MARK: Tests

    @MainActor
    func testPinnedImageIsNilByDefault() {
        XCTAssertNil(sut.pinnedImage, "pinnedImage must start nil on a fresh SuggestionReviewViewModel")
    }

    @MainActor
    func testSettingPhotoDataWithValidJPEGEventuallySetsPinnedImage() async throws {
        let jpeg = try XCTUnwrap(makeMinimalJPEG(), "failed to synthesize test JPEG")
        sut.photoData = jpeg
        await sut.decodeTask?.value
        let image = try XCTUnwrap(sut.pinnedImage, "pinnedImage must be non-nil after valid JPEG photoData")
        XCTAssertGreaterThan(image.size.width, 0, "decoded image must have positive width")
    }

    @MainActor
    func testSettingPhotoDataWithMalformedDataLeavesPinnedImageNil() async throws {
        sut.photoData = Data("not-a-jpeg".utf8)
        await sut.decodeTask?.value
        XCTAssertNil(sut.pinnedImage, "malformed data must leave pinnedImage nil (no crash, no bogus image)")
    }

    @MainActor
    func testSettingPhotoDataToNilClearsPinnedImage() async throws {
        let jpeg = try XCTUnwrap(makeMinimalJPEG(), "failed to synthesize test JPEG")
        sut.photoData = jpeg
        await sut.decodeTask?.value
        XCTAssertNotNil(sut.pinnedImage, "sanity: pinnedImage should populate before we clear photoData")

        sut.photoData = nil
        // Nil path is synchronous on the main actor — no await needed.
        XCTAssertNil(sut.pinnedImage, "setting photoData = nil must clear pinnedImage immediately")
    }

    @MainActor
    func testDecodeRunsOffMainThread() async throws {
        let jpeg = try XCTUnwrap(makeMinimalJPEG(), "failed to synthesize test JPEG")
        let onMainBox = ThreadBox(true)
        let vm = SuggestionReviewViewModel(decoder: { data in
            onMainBox.value = Thread.isMainThread
            return UIImage(data: data)
        })
        vm.photoData = jpeg
        await vm.decodeTask?.value
        XCTAssertFalse(onMainBox.value, "decode must run off the main thread")
    }

    @MainActor
    func testRapidPhotoDataUpdatesSettleToLastValue() async throws {
        let red = try XCTUnwrap(makeSolidColorJPEG(r: 255, g: 0, b: 0), "failed to build red fixture")
        let green = try XCTUnwrap(makeSolidColorJPEG(r: 0, g: 255, b: 0), "failed to build green fixture")
        let blue = try XCTUnwrap(makeSolidColorJPEG(r: 0, g: 0, b: 255), "failed to build blue fixture")

        sut.photoData = red
        sut.photoData = green
        sut.photoData = blue

        // Await the most-recent decode task. Prior tasks were cancelled; this
        // is the one carrying the "blue" generation.
        await sut.decodeTask?.value

        let image = try XCTUnwrap(sut.pinnedImage, "pinnedImage should be non-nil after rapid updates")
        let cg = try XCTUnwrap(image.cgImage, "pinnedImage must have cgImage for pixel sampling")
        let pixel = try XCTUnwrap(readPixel(cgImage: cg, x: 0, y: 0), "failed to sample pixel")

        // Pixel-level assertion — JPEG quantization perturbs exact values, so
        // compare channel dominance instead of equality. Blue channel must
        // dominate R and G.
        XCTAssertGreaterThan(pixel.b, pixel.r, "blue channel should dominate red in final image")
        XCTAssertGreaterThan(pixel.b, pixel.g, "blue channel should dominate green in final image")
    }

    // MARK: - Swift2_013: confirmationErrorMessage for confirm() failures

    /// Empty binId must set a user-visible message that mentions the bin.
    /// The guard in `confirm(binId:apiClient:)` already early-returns; it must
    /// ALSO publish a `confirmationErrorMessage` so the view can toast it.
    func testConfirmWithEmptyBinIdSetsConfirmationErrorMessage() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "", apiClient: client)

        let message = try XCTUnwrap(sut.confirmationErrorMessage,
                                    "confirm with empty binId must publish a user-facing message")
        XCTAssertTrue(message.lowercased().contains("bin"),
                      "message should mention the bin — got: \(message)")
    }

    /// Network-layer failure (e.g. offline) must set a connection-oriented
    /// message, not be swallowed into bare `failedIndices`.
    func testConfirmWithNetworkFailureSetsReadableErrorMessage() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        let message = try XCTUnwrap(sut.confirmationErrorMessage,
                                    "network failure must publish a user-facing message")
        let lower = message.lowercased()
        XCTAssertTrue(lower.contains("connection") || lower.contains("reach"),
                      "message should mention connection/reachability — got: \(message)")
    }

    /// HTTP 401 with no APIError body falls through to
    /// `APIClientError.unexpectedStatusCode(401)` — VM must translate that to
    /// an auth-specific message pointing at Settings.
    func testConfirmWith401SetsAuthErrorMessage() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 401, for: request), Data())
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        let message = try XCTUnwrap(sut.confirmationErrorMessage,
                                    "401 must publish a user-facing message")
        XCTAssertTrue(message.contains("API key") || message.contains("Settings"),
                      "401 message should mention API key or Settings — got: \(message)")
    }

    /// HTTP 500 with no APIError body falls through to
    /// `APIClientError.unexpectedStatusCode(500)` — VM must translate that to
    /// a server-error message.
    func testConfirmWithServer500SetsGenericServerErrorMessage() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), Data())
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        let message = try XCTUnwrap(sut.confirmationErrorMessage,
                                    "500 must publish a user-facing message")
        XCTAssertTrue(message.lowercased().contains("server"),
                      "500 message should mention the server — got: \(message)")
    }

    /// First item succeeds, second fails → partial failure. Message must
    /// count items and use the word "failed" so the user knows what to retry.
    func testConfirmWithPartialFailureSetsWarnMessage() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)
        XCTAssertEqual(sut.editableSuggestions.count, 2, "fixture has two suggestions")

        var upsertAttempt = 0
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            // /items upsert
            upsertAttempt += 1
            if upsertAttempt == 1 {
                return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
            }
            return (mockResponse(statusCode: 500, for: request), Data())
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertFalse(sut.failedIndices.isEmpty, "partial failure should leave failedIndices non-empty")
        let message = try XCTUnwrap(sut.confirmationErrorMessage,
                                    "partial failure must publish a user-facing message")
        let lower = message.lowercased()
        XCTAssertTrue(lower.contains("failed"), "message should contain 'failed' — got: \(message)")
        XCTAssertTrue(message.contains("1"), "message should include failed count (1) — got: \(message)")
        XCTAssertTrue(message.contains("2"), "message should include total count (2) — got: \(message)")
    }

    /// Happy path must not leave a stale error message behind.
    func testConfirmSuccessDoesNotSetErrorMessage() async throws {
        let suggestions = try makeSuggestions()
        sut.loadSuggestions(suggestions)

        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertNil(sut.confirmationErrorMessage,
                     "successful confirm must not leave a stale error message")
        XCTAssertTrue(sut.failedIndices.isEmpty, "no failures expected on happy path")
    }
}
