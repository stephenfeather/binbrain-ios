// BuildConfigTests.swift
// Bin BrainTests
//
// Unit tests for BuildConfig.nonEmpty, exercising the injectable lookup seam.
// The integration (xcconfig → plist → Bundle.main) can only be verified on a
// live build, not in XCTest.

import XCTest
@testable import Bin_Brain

@MainActor
final class BuildConfigTests: XCTestCase {

    override func tearDown() async throws {
        // Reset to the production default so later tests in the suite that
        // read Bundle.main aren't affected.
        BuildConfig.lookup = { key in
            Bundle.main.object(forInfoDictionaryKey: key)
        }
        try await super.tearDown()
    }

    // MARK: - nonEmpty

    func testNonEmptyReturnsNilForMissingKey() {
        BuildConfig.lookup = { _ in nil }
        XCTAssertNil(BuildConfig.nonEmpty("DefaultServerURL"))
    }

    func testNonEmptyReturnsNilForNonStringValue() {
        BuildConfig.lookup = { _ in 42 }
        XCTAssertNil(BuildConfig.nonEmpty("DefaultServerURL"),
                     "Non-string Info.plist values should not surface as config")
    }

    func testNonEmptyReturnsNilForEmptyString() {
        BuildConfig.lookup = { _ in "" }
        XCTAssertNil(BuildConfig.nonEmpty("DefaultAPIKey"),
                     "Release builds substitute $(var) as '' — must be treated as absent")
    }

    func testNonEmptyReturnsNilForWhitespaceOnlyString() {
        BuildConfig.lookup = { _ in "   \n\t" }
        XCTAssertNil(BuildConfig.nonEmpty("DefaultAPIKey"))
    }

    func testNonEmptyReturnsTrimmedValueWhenPresent() {
        BuildConfig.lookup = { _ in "  http://10.1.1.205:8000\n" }
        XCTAssertEqual(BuildConfig.nonEmpty("DefaultServerURL"),
                       "http://10.1.1.205:8000")
    }

    // MARK: - accessors

    func testAccessorsRouteThroughLookupByKey() {
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultServerURL": return "http://example.test:9000"
            case "DefaultAPIKey": return "bb_probe_xxx"
            default: return nil
            }
        }
        XCTAssertEqual(BuildConfig.defaultServerURL, "http://example.test:9000")
        XCTAssertEqual(BuildConfig.defaultAPIKey, "bb_probe_xxx")
    }
}
