// LocalNotificationTests.swift
// Bin BrainTests
//
// Tests for Task 14: PendingAnalysis retry logic and notification-related
// SwiftData operations. Uses an in-memory ModelContainer.

import XCTest
import SwiftData
@testable import Bin_Brain

final class LocalNotificationTests: XCTestCase {

    // MARK: - Properties

    var container: ModelContainer!
    var context: ModelContext!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([PendingUpload.self, PendingAnalysis.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    // MARK: - Test 1: PendingAnalysis created with correct defaults

    /// A freshly created `PendingAnalysis` stores the provided photoId and binId
    /// with `retryCount` defaulting to zero.
    func testPendingAnalysisIsCreatedWithCorrectDefaults() {
        let entry = PendingAnalysis(photoId: 42, binId: "BIN-0001")

        XCTAssertEqual(entry.photoId, 42, "photoId should match the provided value")
        XCTAssertEqual(entry.binId, "BIN-0001", "binId should match the provided value")
        XCTAssertEqual(entry.retryCount, 0, "retryCount should default to 0")
    }

    // MARK: - Test 2: retryCount can be incremented

    /// Verifying that `retryCount` can be incremented past the retry threshold (3).
    func testPendingAnalysisRetryCountIncrement() {
        let entry = PendingAnalysis(photoId: 7, binId: "BIN-0002")

        XCTAssertEqual(entry.retryCount, 0)
        entry.retryCount += 1
        XCTAssertEqual(entry.retryCount, 1)
        entry.retryCount += 1
        XCTAssertEqual(entry.retryCount, 2)
        entry.retryCount += 1
        XCTAssertEqual(entry.retryCount, 3, "retryCount should reach the threshold of 3")
    }

    // MARK: - Test 3: PendingAnalysis can be inserted and fetched from in-memory store

    /// Round-trip test: insert a `PendingAnalysis` into an in-memory context,
    /// fetch it back, and verify all properties are preserved.
    func testPendingAnalysisCanBeInsertedAndFetched() throws {
        let entry = PendingAnalysis(photoId: 42, binId: "BIN-0001")
        context.insert(entry)
        try context.save()

        let descriptor = FetchDescriptor<PendingAnalysis>()
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.count, 1, "Should have exactly one PendingAnalysis in store")
        let item = try XCTUnwrap(fetched.first)
        XCTAssertEqual(item.photoId, 42, "Fetched photoId should match inserted value")
        XCTAssertEqual(item.binId, "BIN-0001", "Fetched binId should match inserted value")
        XCTAssertEqual(item.retryCount, 0, "Fetched retryCount should be 0")
    }

    // MARK: - Test 4: Deletion after retry threshold removes entry from store

    /// Simulates the retry-and-delete pattern: increment retryCount to the threshold,
    /// then delete the entry and verify the store is empty.
    func testDeletionAfterRetryThresholdRemovesEntry() throws {
        let entry = PendingAnalysis(photoId: 55, binId: "BIN-0010")
        context.insert(entry)
        try context.save()

        // Simulate 3 failed retries.
        entry.retryCount += 1
        entry.retryCount += 1
        entry.retryCount += 1

        // At threshold, delete.
        if entry.retryCount >= 3 {
            context.delete(entry)
            try context.save()
        }

        let remaining = try context.fetch(FetchDescriptor<PendingAnalysis>())
        XCTAssertTrue(remaining.isEmpty, "Entry should be deleted after reaching retry threshold")
    }
}
