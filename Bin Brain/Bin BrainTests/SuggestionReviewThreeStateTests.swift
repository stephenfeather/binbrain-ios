// SuggestionReviewThreeStateTests.swift
// Bin BrainTests
//
// Coverage for the Swift2_020 three-state outcome toggle behavior on
// SuggestionReviewViewModel. Existing legacy-mode tests live in
// SuggestionReviewViewModelTests.swift; this file only exercises the
// flag-on (`outcomeModelEnabled = true`) code path so the two modes are
// validated independently.

import XCTest
@testable import Bin_Brain

@MainActor
final class SuggestionReviewThreeStateTests: XCTestCase {

    var sut: SuggestionReviewViewModel!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = SuggestionReviewViewModel()
        sut.threeStateEnabled = true
    }

    override func tearDown() async throws {
        SuggestionReviewMockURLProtocol.requestHandler = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

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

    private func mockResponse(statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
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

    private func makeSuggestions() throws -> [SuggestionItem] {
        let json = Data("""
        [
            {"item_id": null, "name": "Widget", "category": "Hardware", "confidence": 0.92, "bins": ["BIN-0001"]},
            {"item_id": 5, "name": "Bolt", "category": "Fasteners", "confidence": 0.78, "bins": ["BIN-0001"]}
        ]
        """.utf8)
        return try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)
    }

    // MARK: - Default state

    func testNewRowsDefaultToIgnoredUnderThreeState() throws {
        sut.loadSuggestions(try makeSuggestions())

        XCTAssertEqual(sut.editableSuggestions.count, 2)
        XCTAssertTrue(sut.editableSuggestions.allSatisfy { $0.outcomeState == .ignored },
                      "Three-state default for new rows must be .ignored")
        XCTAssertTrue(sut.editableSuggestions.allSatisfy { !$0.included },
                      "Ignored rows must NOT be included in confirm payload")
    }

    // MARK: - Tap cycle

    func testCycleOutcomeAdvancesPerSpec() throws {
        sut.loadSuggestions(try makeSuggestions())
        let id = sut.editableSuggestions[0].id

        sut.cycleOutcome(id: id)
        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, .accepted)
        XCTAssertTrue(sut.editableSuggestions[0].included,
                      "Accepted rows must mirror to included == true so confirm picks them up")

        sut.cycleOutcome(id: id)
        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, .rejected)
        XCTAssertFalse(sut.editableSuggestions[0].included,
                       "Rejected rows must drop out of confirm payload")

        sut.cycleOutcome(id: id)
        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, .ignored,
                       "Three taps must complete the cycle back to ignored")
        XCTAssertFalse(sut.editableSuggestions[0].included)
    }

    func testCycleOutcomeUnknownIdIsNoOp() throws {
        sut.loadSuggestions(try makeSuggestions())
        let snapshot = sut.editableSuggestions.map(\.outcomeState)

        sut.cycleOutcome(id: 9999)

        XCTAssertEqual(sut.editableSuggestions.map(\.outcomeState), snapshot,
                       "Unknown id must not mutate state — Karpathy: surgical changes")
    }

    /// SEC-22-2 (LOW from PR #22 review): tapping the chip while the
    /// upsert loop is in flight previously raced with the confirm-time
    /// `included` filter. The view now disables the Button while
    /// `isConfirming`; the VM-level guard is defence-in-depth so a direct
    /// `cycleOutcome` call from code cannot corrupt state either.
    ///
    /// The mock handler parks the first `/items` request on a
    /// `DispatchSemaphore` so the test can observe `isConfirming = true`,
    /// call `cycleOutcome`, assert it was a no-op, then release the
    /// semaphore to let confirm complete normally.
    func testCycleOutcomeNoOpWhileConfirming() async throws {
        sut.loadSuggestions(try makeSuggestions())
        let id = sut.editableSuggestions[0].id
        sut.cycleOutcome(id: id) // → .accepted so confirm has work to do

        let hitItems = expectation(description: "/items request reached the mock")
        let release = DispatchSemaphore(value: 0)
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path == "/items" {
                hitItems.fulfill()
                // Park the URL handler thread (sync context — `wait` is
                // legal here) until the test releases it.
                release.wait()
                return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
            }
            if path.contains("/outcomes") {
                return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
            }
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        let confirmTask = Task { await sut.confirm(binId: "BIN-0001", apiClient: client) }
        await fulfillment(of: [hitItems], timeout: 2.0)

        XCTAssertTrue(sut.isConfirming, "precondition: confirm must be in flight")
        let before = sut.editableSuggestions[0].outcomeState
        sut.cycleOutcome(id: id)
        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, before,
                       "Cycle must be a no-op while isConfirming — SEC-22-2")

        // Let confirm finish.
        release.signal()
        await confirmTask.value
        XCTAssertFalse(sut.isConfirming)
    }

    // MARK: - Edit-flips-to-accepted

    func testEditingIgnoredRowAutoFlipsToAccepted() throws {
        sut.loadSuggestions(try makeSuggestions())
        let id = sut.editableSuggestions[0].id
        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, .ignored, "precondition: ignored")

        sut.editableSuggestions[0].editedName = "Widget XL"
        sut.noteUserEdit(id: id)

        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, .accepted,
                       "Editing an ignored row implies endorsement → state must auto-flip to .accepted")
        XCTAssertTrue(sut.editableSuggestions[0].included,
                      "Auto-flipped row must be included so the upsert fires")
    }

    func testEditingAcceptedRowDoesNotChangeState() throws {
        sut.loadSuggestions(try makeSuggestions())
        let id = sut.editableSuggestions[0].id
        sut.cycleOutcome(id: id) // → .accepted

        sut.editableSuggestions[0].editedName = "Widget XL"
        sut.noteUserEdit(id: id)

        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, .accepted,
                       "Editing an already-accepted row must stay accepted")
    }

    func testEditingRejectedRowDoesNotResurrectIt() throws {
        sut.loadSuggestions(try makeSuggestions())
        let id = sut.editableSuggestions[0].id
        sut.cycleOutcome(id: id) // .accepted
        sut.cycleOutcome(id: id) // .rejected

        sut.editableSuggestions[0].editedName = "Widget XL"
        sut.noteUserEdit(id: id)

        XCTAssertEqual(sut.editableSuggestions[0].outcomeState, .rejected,
                       "Editing a rejected row must NOT re-include it; user must explicitly tap to revive")
    }

    // MARK: - confirmButtonTitle

    func testConfirmButtonTitleNoIgnored() throws {
        sut.loadSuggestions(try makeSuggestions())
        for s in sut.editableSuggestions { sut.cycleOutcome(id: s.id) } // all → .accepted

        XCTAssertEqual(sut.ignoredCount, 0)
        XCTAssertEqual(sut.confirmButtonTitle, "Confirm",
                       "With zero ignored, the title must read just 'Confirm'")
    }

    func testConfirmButtonTitleReflectsIgnoredCount() throws {
        sut.loadSuggestions(try makeSuggestions())
        // Both default ignored.
        XCTAssertEqual(sut.ignoredCount, 2)
        XCTAssertEqual(sut.confirmButtonTitle, "Confirm (2 ignored)",
                       "Two ignored rows → 'Confirm (2 ignored)'")

        sut.cycleOutcome(id: sut.editableSuggestions[0].id) // → .accepted
        XCTAssertEqual(sut.ignoredCount, 1)
        XCTAssertEqual(sut.confirmButtonTitle, "Confirm (1 ignored)")
    }

    func testConfirmButtonTitleLegacyAlwaysReadsConfirm() throws {
        sut.threeStateEnabled = false
        sut.loadSuggestions(try makeSuggestions())

        XCTAssertEqual(sut.confirmButtonTitle, "Confirm",
                       "Legacy mode must never expose ignored-count in the button label")
    }

    // MARK: - canConfirm under three-state

    func testCanConfirmRequiresAtLeastOneAccepted() throws {
        sut.loadSuggestions(try makeSuggestions())
        XCTAssertFalse(sut.canConfirm,
                       "All-ignored should not allow confirm — there's nothing to upsert")

        sut.cycleOutcome(id: sut.editableSuggestions[0].id) // → .accepted
        XCTAssertTrue(sut.canConfirm,
                      "One accepted row must enable confirm even if others are ignored/rejected")
    }

    // MARK: - Confirm payload — outcome decisions

    func testConfirmEmitsAcceptedAndIgnoredDecisionsInPayload() async throws {
        sut.loadSuggestions(try makeSuggestions(),
                            photoId: 42,
                            visionModel: "vision-test",
                            promptVersion: "v1")
        // Accept the first row, leave the second .ignored.
        sut.cycleOutcome(id: sut.editableSuggestions[0].id)

        let outcomesBody = OutcomesBodyCapture()
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/outcomes") {
                outcomesBody.set(request.bodyData)
                return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
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
        // Outcomes are fire-and-forget; give the spawned Task a chance to complete.
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        let body = try XCTUnwrap(outcomesBody.value, "outcomes POST must fire on confirm-success")
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let decisions = try XCTUnwrap(payload?["decisions"] as? [[String: Any]],
                                      "payload must include decisions array")
        let decisionValues = decisions.compactMap { $0["decision"] as? String }
        XCTAssertEqual(Set(decisionValues), Set(["accepted", "ignored"]),
                       "Per-row decision must reflect each row's outcomeState; got \(decisionValues)")
    }

    func testConfirmEmitsRejectedDecision() async throws {
        sut.loadSuggestions(try makeSuggestions(),
                            photoId: 7,
                            visionModel: "vision-test",
                            promptVersion: nil)
        sut.cycleOutcome(id: sut.editableSuggestions[0].id) // → .accepted
        sut.cycleOutcome(id: sut.editableSuggestions[1].id) // → .accepted
        sut.cycleOutcome(id: sut.editableSuggestions[1].id) // → .rejected

        let outcomesBody = OutcomesBodyCapture()
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/outcomes") {
                outcomesBody.set(request.bodyData)
                return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
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
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        let body = try XCTUnwrap(outcomesBody.value)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let decisions = try XCTUnwrap(payload?["decisions"] as? [[String: Any]])
        let decisionValues = decisions.compactMap { $0["decision"] as? String }
        XCTAssertEqual(Set(decisionValues), Set(["accepted", "rejected"]),
                       "Mixed accepted+rejected must surface both decisions; got \(decisionValues)")
    }

    func testConfirmRejectedRowsDoNotUpsert() async throws {
        sut.loadSuggestions(try makeSuggestions())
        // Cycle both rows to .rejected.
        for s in sut.editableSuggestions {
            sut.cycleOutcome(id: s.id) // .accepted
            sut.cycleOutcome(id: s.id) // .rejected
        }

        var upsertCount = 0
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path == "/items" { upsertCount += 1 }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(upsertCount, 0,
                       "Rejected rows must not hit /items — only .accepted upserts")
    }

    func testConfirmEditedAcceptedRowEmitsEditedDecision() async throws {
        sut.loadSuggestions(try makeSuggestions(),
                            photoId: 11,
                            visionModel: "vision-test",
                            promptVersion: "v1")
        let id = sut.editableSuggestions[0].id
        sut.cycleOutcome(id: id) // .accepted
        sut.editableSuggestions[0].editedName = "Renamed Widget"
        // Second row stays ignored.

        let outcomesBody = OutcomesBodyCapture()
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/outcomes") {
                outcomesBody.set(request.bodyData)
                return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
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
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        let body = try XCTUnwrap(outcomesBody.value)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let decisions = try XCTUnwrap(payload?["decisions"] as? [[String: Any]])
        let edited = decisions.first { ($0["label"] as? String) == "Widget" }
        XCTAssertEqual(edited?["decision"] as? String, "edited",
                       "An accepted row whose name diverged from the prefilled label must emit .edited")
        XCTAssertEqual(edited?["edited_to_label"] as? String, "Renamed Widget")
    }

    // MARK: - Feature-flag-off mirrors legacy

    func testFlagOffDefaultsRowsToAccepted() throws {
        sut.threeStateEnabled = false
        sut.loadSuggestions(try makeSuggestions())

        XCTAssertTrue(sut.editableSuggestions.allSatisfy { $0.outcomeState == .accepted },
                      "Legacy mode preserves default-on UX: rows arrive accepted")
        XCTAssertTrue(sut.editableSuggestions.allSatisfy { $0.included },
                      "Legacy mode keeps included == true so confirm uploads everything")
        XCTAssertEqual(sut.ignoredCount, 0)
    }

    func testFlagOffNeverEmitsIgnoredDecision() async throws {
        sut.threeStateEnabled = false
        sut.loadSuggestions(try makeSuggestions(),
                            photoId: 99,
                            visionModel: "vision-test",
                            promptVersion: nil)
        // Exclude the second row the legacy way.
        sut.editableSuggestions[1].included = false

        let outcomesBody = OutcomesBodyCapture()
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/outcomes") {
                outcomesBody.set(request.bodyData)
                return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
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
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        let body = try XCTUnwrap(outcomesBody.value)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let decisions = try XCTUnwrap(payload?["decisions"] as? [[String: Any]])
        let decisionValues = decisions.compactMap { $0["decision"] as? String }
        XCTAssertFalse(decisionValues.contains("ignored"),
                       "Legacy mode must never emit .ignored — old payload semantics preserved")
        XCTAssertEqual(Set(decisionValues), Set(["accepted", "rejected"]),
                       "Legacy mode classifies excluded rows as .rejected")
    }
}

// MARK: - Helpers

/// File-local mirror of the `bodyData` helper in SuggestionReviewViewModelTests
/// so this file does not need a cross-file `internal` extension. Reads the
/// request body from `httpBody` or drains `httpBodyStream` as a fallback.
private extension URLRequest {
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

/// Locked Data box so the URLProtocol callback (executed on a background
/// queue) can hand a captured request body back to the test thread without
/// triggering Swift 6 sendable warnings. File-private to avoid polluting
/// the test target's symbol namespace (Copilot review feedback).
private final class OutcomesBodyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func set(_ data: Data?) {
        lock.lock(); defer { lock.unlock() }
        stored = data
    }
    var value: Data? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
