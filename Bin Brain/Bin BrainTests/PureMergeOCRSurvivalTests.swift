// PureMergeOCRSurvivalTests.swift
// Bin BrainTests
//
// Swift_prong1_ocr_preliminary — unit tests for the pure merge function's
// handling of `origin == .ocr` chips. OCR chips must survive the server
// response like `.edited` chips do, and server entries that normalize to
// the same name as an OCR chip must be skipped (deduped).
//
// Driven against `SuggestionReviewViewModel.merge(preliminary:server:)`
// directly so the contract is pinned at the function boundary, independent
// of the VM's load paths.

import XCTest
@testable import Bin_Brain

@MainActor
final class PureMergeOCRSurvivalTests: XCTestCase {

    // MARK: - Fixtures

    private func makeOCR(id: Int, name: String, confidence: Double = 1.0) -> EditableSuggestion {
        EditableSuggestion(
            id: id,
            included: true,
            editedName: name,
            editedCategory: "",
            editedQuantity: "",
            confidence: confidence,
            visionName: name,
            match: nil,
            bbox: nil,
            teach: true,
            origin: .ocr,
            originalCategory: nil
        )
    }

    private func makePreliminary(id: Int, name: String) -> EditableSuggestion {
        EditableSuggestion(
            id: id,
            included: true,
            editedName: name,
            editedCategory: "",
            editedQuantity: "",
            confidence: 0.8,
            visionName: name,
            match: nil,
            bbox: nil,
            teach: true,
            origin: .preliminary,
            originalCategory: nil
        )
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

    // MARK: - Survival

    func testOCRChipSurvivesEmptyServerResponse() {
        let prelim = [makeOCR(id: 0, name: "Elegoo Ribbon Cables")]

        let merged = SuggestionReviewViewModel.merge(preliminary: prelim, server: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].editedName, "Elegoo Ribbon Cables")
        XCTAssertEqual(merged[0].origin, .ocr)
    }

    func testOCRChipSurvivesServerDisagrees() throws {
        let prelim = [makeOCR(id: 0, name: "Elegoo Ribbon Cables")]
        let server = try serverItems(["label_packaging"])

        let merged = SuggestionReviewViewModel.merge(preliminary: prelim, server: server)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].editedName, "Elegoo Ribbon Cables")
        XCTAssertEqual(merged[0].origin, .ocr)
        XCTAssertEqual(merged[1].editedName, "label_packaging")
        XCTAssertEqual(merged[1].origin, .server)
    }

    func testServerEntryMatchingOCRNameIsDeduped() throws {
        let prelim = [makeOCR(id: 0, name: "bolt kit")]
        let server = try serverItems(["bolt kit", "screw"])

        let merged = SuggestionReviewViewModel.merge(preliminary: prelim, server: server)

        XCTAssertEqual(merged.count, 2,
                       "Server entry overlapping an OCR chip must be deduped")
        XCTAssertEqual(merged[0].origin, .ocr,
                       "OCR chip wins over overlapping server entry")
        XCTAssertEqual(merged[1].editedName, "screw")
        XCTAssertEqual(merged[1].origin, .server)
    }

    func testOCRDedupeIsCaseAndWhitespaceInsensitive() throws {
        let prelim = [makeOCR(id: 0, name: "  Bolt Kit  ")]
        let server = try serverItems(["bolt kit"])

        let merged = SuggestionReviewViewModel.merge(preliminary: prelim, server: server)

        XCTAssertEqual(merged.count, 1,
                       "Normalization (trim + lowercase) must catch this dedupe")
        XCTAssertEqual(merged[0].origin, .ocr)
    }

    // MARK: - Coexistence with .edited and .preliminary

    func testEditedAndOCRChipsBothSurvive() throws {
        let prelim: [EditableSuggestion] = [
            makePreliminary(id: 0, name: "nail"),
            makeOCR(id: 1, name: "Elegoo Ribbon Cables")
        ]
        var edited = prelim
        edited[0].editedName = "M3 screw"
        edited[0].origin = .edited
        let server = try serverItems(["bolt"])

        let merged = SuggestionReviewViewModel.merge(preliminary: edited, server: server)

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(Set(merged.map(\.origin)), [.edited, .ocr, .server])
        XCTAssertTrue(merged.contains(where: { $0.editedName == "M3 screw" && $0.origin == .edited }))
        XCTAssertTrue(merged.contains(where: { $0.editedName == "Elegoo Ribbon Cables" && $0.origin == .ocr }))
        XCTAssertTrue(merged.contains(where: { $0.editedName == "bolt" && $0.origin == .server }))
    }

    func testUntouchedPreliminaryIsStillDroppedWhenOCRSurvives() throws {
        // Regression guard: .ocr survival must not accidentally resurrect
        // .preliminary chips. Only .ocr and .edited qualify.
        let prelim: [EditableSuggestion] = [
            makePreliminary(id: 0, name: "nail"),
            makeOCR(id: 1, name: "Elegoo Ribbon Cables")
        ]
        let server = try serverItems(["bolt"])

        let merged = SuggestionReviewViewModel.merge(preliminary: prelim, server: server)

        XCTAssertEqual(merged.count, 2)
        XCTAssertFalse(merged.contains(where: { $0.editedName == "nail" }),
                       "Untouched .preliminary must still be dropped when server returns")
        XCTAssertTrue(merged.contains(where: { $0.editedName == "Elegoo Ribbon Cables" }))
        XCTAssertTrue(merged.contains(where: { $0.editedName == "bolt" }))
    }
}
