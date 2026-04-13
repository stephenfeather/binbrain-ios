// LogPrivacyTests.swift
// Bin BrainTests
//
// Compile-only regression test for os.Logger privacy-marker syntax.
// The interpolation-privacy API is strict; keeping this test ensures a
// syntax mistake in any redacted logger call is caught at build time.

import XCTest
@testable import Bin_Brain

final class LogPrivacyTests: XCTestCase {
    func testModuleCompilesWithRedactedLoggerCalls() {
        XCTAssertTrue(true)
    }
}
