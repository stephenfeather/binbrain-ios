// OutcomeStateTests.swift
// Bin BrainTests
//
// Coverage for the three-state outcome enum used by Swift2_020.
// The enum is the foundation of the tap-cycle UI: ignored (yellow, default)
// → accepted (green) → rejected (red) → ignored. Server payloads use the
// `serverDecision` mapping so the wire format stays stable.

import XCTest
@testable import Bin_Brain

final class OutcomeStateTests: XCTestCase {

    // MARK: - Tap cycle

    func testNextFromIgnoredYieldsAccepted() {
        XCTAssertEqual(OutcomeState.ignored.next(), .accepted,
                       "First tap on an ignored row must advance to accepted")
    }

    func testNextFromAcceptedYieldsRejected() {
        XCTAssertEqual(OutcomeState.accepted.next(), .rejected,
                       "Second tap must advance from accepted to rejected")
    }

    func testNextFromRejectedYieldsIgnored() {
        XCTAssertEqual(OutcomeState.rejected.next(), .ignored,
                       "Third tap must wrap rejected back to ignored")
    }

    func testThreeTapsReturnToIgnored() {
        let result = OutcomeState.ignored.next().next().next()
        XCTAssertEqual(result, .ignored,
                       "Three taps starting from ignored must complete the cycle")
    }

    // MARK: - Server-decision mapping

    func testServerDecisionMappingMatchesSpec() {
        XCTAssertEqual(OutcomeState.ignored.serverDecision, "ignored")
        XCTAssertEqual(OutcomeState.accepted.serverDecision, "accepted")
        XCTAssertEqual(OutcomeState.rejected.serverDecision, "rejected")
    }

    func testAllCasesIsExactlyThreeStates() {
        XCTAssertEqual(OutcomeState.allCases.count, 3,
                       "Three-state model must have exactly three cases")
        XCTAssertTrue(OutcomeState.allCases.contains(.ignored))
        XCTAssertTrue(OutcomeState.allCases.contains(.accepted))
        XCTAssertTrue(OutcomeState.allCases.contains(.rejected))
    }
}
