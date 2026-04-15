// SuggestionReviewViewModelPreliminaryTests.swift
// Bin BrainTests
//
// RED tests for CoreML Mode A Phase 1 (Swift2_001_coreml_phase1_mode_a.md).
// Covers loading on-device `VNClassifyImageRequest` results as preliminary
// chips and merging them with the server's `[SuggestionItem]` per the
// merge-UX spike (thoughts/shared/designs/coreml-mode-a-merge-ux.md §2a).

import XCTest
@testable import Bin_Brain

@MainActor
final class SuggestionReviewViewModelPreliminaryTests: XCTestCase {

    var sut: SuggestionReviewViewModel!

    override func setUp() async throws {
        try await super.setUp()
        sut = SuggestionReviewViewModel()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func classifications(_ pairs: [(String, Float)]) -> [ClassificationResult] {
        pairs.map { ClassificationResult(label: $0.0, confidence: $0.1) }
    }

    private func serverItems(_ names: [String]) throws -> [SuggestionItem] {
        let items = names.map { name in
            """
            {"item_id": null, "name": "\(name)", "category": null, "confidence": 0.9, "bins": []}
            """
        }
        let json = Data("[\(items.joined(separator: ","))]".utf8)
        return try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)
    }

    // MARK: - Load preliminaries

    func testLoadPreliminaryClassificationsRendersTopK() {
        let cls = classifications([("screw", 0.91), ("nail", 0.62), ("bolt", 0.33), ("washer", 0.11)])

        sut.loadPreliminaryClassifications(cls, topK: 3)

        XCTAssertEqual(sut.editableSuggestions.count, 3, "Should render top-K=3 preliminary chips")
        XCTAssertEqual(sut.editableSuggestions.map(\.editedName), ["screw", "nail", "bolt"])
        XCTAssertTrue(sut.editableSuggestions.allSatisfy { $0.origin == .preliminary },
                      "All chips loaded from classifications should be preliminary")
        XCTAssertTrue(sut.editableSuggestions.allSatisfy { $0.included },
                      "Preliminaries default to included")
    }

    func testLoadPreliminaryWithFewerClassificationsThanTopK() {
        let cls = classifications([("screw", 0.91)])

        sut.loadPreliminaryClassifications(cls, topK: 3)

        XCTAssertEqual(sut.editableSuggestions.count, 1, "Should cap at available classifications")
    }

    func testLoadEmptyPreliminariesFallsBackToEmptyState() {
        sut.loadPreliminaryClassifications([], topK: 3)

        XCTAssertTrue(sut.editableSuggestions.isEmpty,
                      "Empty classifications must not create chips (fallback to today's behavior)")
    }

    // MARK: - Merge: server agrees

    func testServerAgreesPromotesPreliminaryToServer() throws {
        sut.loadPreliminaryClassifications(classifications([("screw", 0.91), ("nail", 0.62)]), topK: 3)
        let server = try serverItems(["screw"])

        sut.applyServerSuggestions(server)

        // "screw" was in preliminary, server agrees → promoted to .server.
        // "nail" was an untouched preliminary with no server match → dropped.
        XCTAssertEqual(sut.editableSuggestions.count, 1, "Untouched preliminaries with no server match are dropped")
        let chip = try XCTUnwrap(sut.editableSuggestions.first)
        XCTAssertEqual(chip.editedName, "screw")
        XCTAssertEqual(chip.origin, .server, "Preliminary matched by server should become .server origin")
    }

    // MARK: - Merge: server disagrees

    func testServerDisagreesReplacesUntouchedPreliminaries() throws {
        sut.loadPreliminaryClassifications(classifications([("nail", 0.71), ("washer", 0.40)]), topK: 3)
        let server = try serverItems(["bolt", "screw"])

        sut.applyServerSuggestions(server)

        // All preliminaries were untouched and non-overlapping with server → dropped.
        // Server chips appear fresh.
        XCTAssertEqual(sut.editableSuggestions.map(\.editedName), ["bolt", "screw"])
        XCTAssertTrue(sut.editableSuggestions.allSatisfy { $0.origin == .server })
    }

    // MARK: - Merge: server empty

    func testServerEmptyDropsUntouchedPreliminaries() {
        sut.loadPreliminaryClassifications(classifications([("screw", 0.91)]), topK: 3)

        sut.applyServerSuggestions([])

        // Architect's clarification: downstream empty-state UI must see a clean [] when
        // preliminaries are untouched and server is empty — no stale preliminary flash.
        XCTAssertTrue(sut.editableSuggestions.isEmpty,
                      "Server-empty + untouched preliminaries must produce [] (clean empty state)")
    }

    // MARK: - Merge: user edits survive

    func testUserEditOnPreliminarySurvivesServerResponse() throws {
        sut.loadPreliminaryClassifications(classifications([("nail", 0.71)]), topK: 3)

        // Simulate user editing the preliminary chip before the server returns.
        sut.editableSuggestions[0].editedName = "M3 screw"
        sut.markEdited(index: 0)

        let server = try serverItems(["bolt"])
        sut.applyServerSuggestions(server)

        // User's edited chip survives; server's non-overlapping chip is appended.
        XCTAssertEqual(sut.editableSuggestions.count, 2)
        XCTAssertEqual(sut.editableSuggestions[0].editedName, "M3 screw", "User edit preserved")
        XCTAssertEqual(sut.editableSuggestions[0].origin, .edited)
        XCTAssertEqual(sut.editableSuggestions[1].editedName, "bolt")
        XCTAssertEqual(sut.editableSuggestions[1].origin, .server)
    }

    func testUserEditOverlappingServerNameDoesNotDuplicate() throws {
        sut.loadPreliminaryClassifications(classifications([("nail", 0.71)]), topK: 3)
        sut.editableSuggestions[0].editedName = "bolt"
        sut.markEdited(index: 0)

        let server = try serverItems(["bolt", "screw"])
        sut.applyServerSuggestions(server)

        // User edited to "bolt"; server also says "bolt". Keep user's, skip server's duplicate.
        XCTAssertEqual(sut.editableSuggestions.count, 2, "No duplicate when user edit matches a server name")
        XCTAssertEqual(sut.editableSuggestions[0].editedName, "bolt")
        XCTAssertEqual(sut.editableSuggestions[0].origin, .edited)
        XCTAssertEqual(sut.editableSuggestions[1].editedName, "screw")
        XCTAssertEqual(sut.editableSuggestions[1].origin, .server)
    }

    // MARK: - Pure merge function

    func testPureMergeFunctionIsDeterministic() throws {
        let prelim: [EditableSuggestion] = [
            .makePreliminary(id: 0, name: "nail", confidence: 0.71),
            .makePreliminary(id: 1, name: "screw", confidence: 0.40)
        ]
        let server = try serverItems(["screw", "bolt"])

        let merged = SuggestionReviewViewModel.merge(preliminary: prelim, server: server)

        // "screw" matches server → promoted. "nail" untouched + no server match → dropped.
        // "bolt" is server-only → appended.
        XCTAssertEqual(merged.map(\.editedName), ["screw", "bolt"])
        XCTAssertTrue(merged.allSatisfy { $0.origin == .server })
    }
}

// MARK: - Test helpers

private extension EditableSuggestion {
    /// Builds a preliminary `EditableSuggestion` for isolated merge-function tests.
    static func makePreliminary(id: Int, name: String, confidence: Double) -> EditableSuggestion {
        EditableSuggestion(
            id: id,
            included: true,
            editedName: name,
            editedCategory: "",
            editedQuantity: "",
            confidence: confidence,
            visionName: name,
            match: nil,
            teach: true,
            origin: .preliminary
        )
    }
}
