// BinNameValidatorTests.swift
// Bin BrainTests
//
// XCTest coverage for BinNameValidator.swift (Swift2_023). The validator is
// pure — no async, no I/O, no Vision — so this is straight assertion table.

import XCTest
@testable import Bin_Brain

final class BinNameValidatorTests: XCTestCase {

    // MARK: - Truthy: must be rejected as reserved

    func testCaseInsensitiveUnassignedVariantsAreReserved() {
        XCTAssertTrue(BinNameValidator.isReserved("UNASSIGNED"))
        XCTAssertTrue(BinNameValidator.isReserved("unassigned"))
        XCTAssertTrue(BinNameValidator.isReserved("Unassigned"))
        XCTAssertTrue(BinNameValidator.isReserved("uNaSsIgNeD"))
    }

    func testCaseInsensitiveBinlessVariantsAreReserved() {
        XCTAssertTrue(BinNameValidator.isReserved("Binless"))
        XCTAssertTrue(BinNameValidator.isReserved("BINLESS"))
        XCTAssertTrue(BinNameValidator.isReserved("binless"))
    }

    func testWhitespaceTrimmingMatchesReservedNames() {
        XCTAssertTrue(BinNameValidator.isReserved("  UNASSIGNED  "),
                      "Leading/trailing whitespace must be trimmed before the reserved-set check")
        XCTAssertTrue(BinNameValidator.isReserved("Binless\n"),
                      "Trailing newline must be trimmed too — paste-from-clipboard often carries them")
        XCTAssertTrue(BinNameValidator.isReserved("\tunassigned\t"))
    }

    // MARK: - Falsy: must NOT be rejected

    func testCommonNonReservedNamesArePermitted() {
        XCTAssertFalse(BinNameValidator.isReserved("kitchen"))
        XCTAssertFalse(BinNameValidator.isReserved("BIN-0001"))
        XCTAssertFalse(BinNameValidator.isReserved("garage-shelf-A"))
    }

    func testEmptyAndWhitespaceOnlyAreNotReserved() {
        // These fail other validators (QR pattern, form non-empty), but the
        // reserved-name check is orthogonal — it answers "is this exact name
        // on the reserved list?", not "is this name valid?".
        XCTAssertFalse(BinNameValidator.isReserved(""))
        XCTAssertFalse(BinNameValidator.isReserved(" "))
        XCTAssertFalse(BinNameValidator.isReserved("\n\t"))
    }

    func testSubstringsContainingReservedTokenAreNotReserved() {
        // The match is exact-after-normalize, not substring — names that
        // *contain* "unassigned" must pass.
        XCTAssertFalse(BinNameValidator.isReserved("unassigned-tools"))
        XCTAssertFalse(BinNameValidator.isReserved("my binless bin"))
    }

    // MARK: - Friendly message

    func testFriendlyMessageNamesTheTrimmedInput() {
        let msg = BinNameValidator.friendlyMessage(for: "  UNASSIGNED  ")
        XCTAssertTrue(msg.contains("'UNASSIGNED'"),
                      "Message must quote the user's input verbatim (after trim) so they see what was rejected")
        XCTAssertTrue(msg.contains("reserved"),
                      "Message must explain why the name was rejected")
    }
}
