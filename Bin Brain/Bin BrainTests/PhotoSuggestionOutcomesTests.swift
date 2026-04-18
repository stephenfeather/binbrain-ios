// PhotoSuggestionOutcomesTests.swift
// Bin BrainTests
//
// Swift2_014 — Rejection Outcomes (iOS).
// Covers the pure `buildOutcomes` decision builder AND the fire-and-forget
// POST /photos/{id}/outcomes integration surface on SuggestionReviewViewModel.
//
// Idiom matches SuggestionReviewViewModelTests (URLProtocol-based mock). The
// mock name is file-local to avoid symbol collisions across test bundles.

import XCTest
import UIKit
@testable import Bin_Brain

// MARK: - OutcomesMockURLProtocol

/// URLProtocol subclass that intercepts requests for PhotoSuggestionOutcomesTests.
///
/// Distinct class name from `SuggestionReviewMockURLProtocol` and
/// `AnalysisMockURLProtocol` to avoid link-time collisions in the shared test
/// bundle. Handlers return (status, body) synchronously.
final class OutcomesMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = OutcomesMockURLProtocol.requestHandler else {
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
    var outcomesBodyData: Data? {
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

// MARK: - PhotoSuggestionOutcomesTests

@MainActor
final class PhotoSuggestionOutcomesTests: XCTestCase {

    var sut: SuggestionReviewViewModel!

    override func setUp() async throws {
        try await super.setUp()
        sut = SuggestionReviewViewModel()
    }

    override func tearDown() async throws {
        OutcomesMockURLProtocol.requestHandler = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private let fixedShownAt = Date(timeIntervalSince1970: 1_744_920_000) // 2026-04-17T20:00:00Z

    private func makeEditable(
        id: Int,
        name: String,
        included: Bool = true,
        editedName: String? = nil,
        category: String? = "fastener",
        confidence: Double = 0.9,
        bbox: [Float]? = [0.1, 0.2, 0.3, 0.4]
    ) -> EditableSuggestion {
        EditableSuggestion(
            id: id,
            included: included,
            editedName: editedName ?? name,
            editedCategory: category ?? "",
            editedQuantity: "",
            confidence: confidence,
            visionName: name,
            match: nil,
            bbox: bbox,
            teach: true,
            origin: .server,
            originalCategory: category
        )
    }

    private func makeSuggestionsJSON() throws -> [SuggestionItem] {
        let json = Data("""
        [
            {"item_id": null, "name": "hex bolt", "category": "fastener", "confidence": 0.91, "bins": [], "bbox": [0.12, 0.34, 0.40, 0.68]},
            {"item_id": null, "name": "lamp base", "category": null, "confidence": 0.74, "bins": []}
        ]
        """.utf8)
        return try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)
    }

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        OutcomesMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutcomesMockURLProtocol.self]
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

    private var upsertSuccessJSON: Data {
        Data(#"{"version":"1","item_id":101,"fingerprint":"hex_bolt|fastener","name":"hex bolt","category":"fastener"}"#.utf8)
    }

    private var associateSuccessJSON: Data {
        Data(#"{"ok":true,"bin_id":"BIN-0001","item_id":101}"#.utf8)
    }

    private var confirmClassSuccessJSON: Data {
        Data(#"{"version":"1","class_name":"hex bolt","added":true,"active_class_count":47,"reload_triggered":true}"#.utf8)
    }

    private var outcomesSuccessJSON: Data {
        Data(#"{"version":"1","photo_id":42,"outcomes_recorded":2}"#.utf8)
    }

    // MARK: - 1. accepted decisions for confirmed selections

    func testBuildOutcomes_acceptedDecisionsProducedForConfirmedSelections() {
        let editable = [
            makeEditable(id: 0, name: "hex bolt", confidence: 0.91, bbox: [0.12, 0.34, 0.40, 0.68])
        ]
        let outcomes = SuggestionReviewViewModel.buildOutcomes(
            shownAt: fixedShownAt,
            editable: editable,
            confirmedIds: [0]
        )
        XCTAssertEqual(outcomes.count, 1)
        let o = outcomes[0]
        XCTAssertEqual(o.decision, .accepted)
        XCTAssertEqual(o.label, "hex bolt")
        XCTAssertEqual(o.category, "fastener")
        XCTAssertEqual(o.confidence, 0.91)
        XCTAssertEqual(o.bbox, [0.12, 0.34, 0.40, 0.68])
        XCTAssertEqual(o.shownAt, fixedShownAt)
        XCTAssertNil(o.editedToLabel)
    }

    // MARK: - 2. rejected for unselected suggestions

    func testBuildOutcomes_rejectedForUnselectedSuggestions() {
        let editable = [
            makeEditable(id: 0, name: "hex bolt"),
            makeEditable(id: 1, name: "lamp base"),
            makeEditable(id: 2, name: "plastic gear")
        ]
        // User confirmed only id 0 (e.g. toggled off 1 and 2 before confirm).
        let outcomes = SuggestionReviewViewModel.buildOutcomes(
            shownAt: fixedShownAt,
            editable: editable,
            confirmedIds: [0]
        )
        XCTAssertEqual(outcomes.count, 3)
        let decisionsByLabel = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.label, $0.decision) })
        XCTAssertEqual(decisionsByLabel["hex bolt"], .accepted)
        XCTAssertEqual(decisionsByLabel["lamp base"], .rejected)
        XCTAssertEqual(decisionsByLabel["plastic gear"], .rejected)
        // Rejected items carry no edited_to_label.
        for o in outcomes where o.decision == .rejected {
            XCTAssertNil(o.editedToLabel, "rejected decisions must not carry edited_to_label")
        }
    }

    // MARK: - 3. edited decision when label changed

    func testBuildOutcomes_editedDecisionWhenLabelChanged() {
        let editable = [
            makeEditable(id: 0, name: "screw", editedName: "M5 bolt")
        ]
        let outcomes = SuggestionReviewViewModel.buildOutcomes(
            shownAt: fixedShownAt,
            editable: editable,
            confirmedIds: [0]
        )
        XCTAssertEqual(outcomes.count, 1)
        let o = outcomes[0]
        XCTAssertEqual(o.decision, .edited)
        XCTAssertEqual(o.label, "screw", "label must be the original VLM suggestion (vision name)")
        XCTAssertEqual(o.editedToLabel, "M5 bolt", "edited_to_label must be the final user-chosen label")
    }

    // MARK: - 4. shownAt propagates from VM timestamp

    func testBuildOutcomes_shownAtPropagatesFromVMTimestamp() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let editable = [
            makeEditable(id: 0, name: "hex bolt"),
            makeEditable(id: 1, name: "lamp base", included: false)
        ]
        let outcomes = SuggestionReviewViewModel.buildOutcomes(
            shownAt: stamp,
            editable: editable,
            confirmedIds: [0]
        )
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.shownAt == stamp },
                      "every outcome must inherit the VM-captured shownAt")
    }

    // MARK: - 5. bbox pass-through

    func testBuildOutcomes_bboxPassesThroughWhenPresentNilWhenAbsent() {
        let editable = [
            makeEditable(id: 0, name: "hex bolt", bbox: [0.1, 0.2, 0.3, 0.4]),
            makeEditable(id: 1, name: "lamp base", bbox: nil)
        ]
        let outcomes = SuggestionReviewViewModel.buildOutcomes(
            shownAt: fixedShownAt,
            editable: editable,
            confirmedIds: [0, 1]
        )
        let boxByLabel = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.label, $0.bbox) })
        XCTAssertEqual(boxByLabel["hex bolt"], [0.1, 0.2, 0.3, 0.4])
        XCTAssertNil(boxByLabel["lamp base"] ?? nil, "absent bbox must round-trip as nil")
    }

    // MARK: - 6. confirm success fires outcomes POST with expected payload

    func testConfirmSuccess_firesOutcomesPostWithExpectedPayload() async throws {
        let suggestions = try makeSuggestionsJSON()
        sut.loadSuggestions(suggestions, photoId: 42, visionModel: "qwen3p6-plus", promptVersion: nil)
        // Toggle off "lamp base" so we have one accepted, one rejected.
        sut.editableSuggestions[1].included = false

        let expectation = XCTestExpectation(description: "POST /photos/42/outcomes is invoked")
        let capturedBody = CapturedBody()
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/outcomes") {
                capturedBody.data = request.outcomesBodyData
                expectation.fulfill()
                return (mockResponse(statusCode: 200, for: request), outcomesSuccessJSON)
            }
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)
        await fulfillment(of: [expectation], timeout: 2.0)

        let body = try XCTUnwrap(capturedBody.data, "outcomes request body must be captured")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any],
                                 "outcomes body must be JSON object")
        XCTAssertEqual(json["vision_model"] as? String, "qwen3p6-plus")
        let decisions = try XCTUnwrap(json["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.count, 2, "both presented suggestions must be reported")
        let decisionKinds = Set(decisions.compactMap { $0["decision"] as? String })
        XCTAssertEqual(decisionKinds, ["accepted", "rejected"],
                       "one accepted + one rejected when user confirms 1 of 2")
        XCTAssertTrue(decisions.allSatisfy { $0["shown_at"] != nil },
                      "each decision must carry shown_at")
    }

    // MARK: - 7. outcomes failure does not surface or set confirmationErrorMessage

    func testConfirmSuccess_outcomesFailureDoesNotSurfaceOrSetError() async throws {
        let suggestions = try makeSuggestionsJSON()
        sut.loadSuggestions(suggestions, photoId: 42, visionModel: "qwen3p6-plus", promptVersion: nil)

        let outcomesCalled = XCTestExpectation(description: "outcomes POST attempted")
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/outcomes") {
                outcomesCalled.fulfill()
                return (mockResponse(statusCode: 500, for: request), Data())
            }
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)
        await fulfillment(of: [outcomesCalled], timeout: 2.0)
        // Give the detached Task one extra yield to process the 500 and reach its catch.
        await Task.yield()

        XCTAssertNil(sut.confirmationErrorMessage,
                     "outcomes 500 must NOT surface via confirmationErrorMessage")
        XCTAssertTrue(sut.failedIndices.isEmpty,
                      "outcomes failure must not taint confirm's success state")
    }

    // MARK: - 8. confirm failure does NOT fire outcomes

    func testConfirmFailure_doesNotFireOutcomesPost() async throws {
        let suggestions = try makeSuggestionsJSON()
        sut.loadSuggestions(suggestions, photoId: 42, visionModel: "qwen3p6-plus", promptVersion: nil)

        let outcomesCallCount = CallCounter()
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/outcomes") {
                outcomesCallCount.increment()
                return (mockResponse(statusCode: 200, for: request), outcomesSuccessJSON)
            }
            // First upsert fails → confirm aborts before teach loop or outcomes.
            return (mockResponse(statusCode: 500, for: request), Data())
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)
        // Give any stray background tasks time to fire (there should be none).
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(sut.failedIndices.isEmpty, "confirm failed — failedIndices must be non-empty")
        XCTAssertEqual(outcomesCallCount.value, 0,
                       "outcomes POST MUST NOT fire when confirm fails")
    }

    // MARK: - 9. empty suggestions → empty decisions, no fire

    func testBuildOutcomes_emptySuggestionsListProducesEmptyDecisions() {
        let outcomes = SuggestionReviewViewModel.buildOutcomes(
            shownAt: fixedShownAt,
            editable: [],
            confirmedIds: []
        )
        XCTAssertTrue(outcomes.isEmpty, "no presented suggestions → no decisions")
    }
}

// MARK: - Test helpers

/// Thread-safe box to capture request bodies from the URLProtocol handler.
///
/// `@MainActor` tests stream data from the handler thread; wrapping in a
/// reference type lets the handler's escaping closure write while the test
/// body reads after `fulfillment(of:)` returns.
private final class CapturedBody: @unchecked Sendable {
    var data: Data?
}

/// Atomic counter for mock invocation counts.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
