// PendingAnalysisTests.swift
// Bin BrainTests
//
// XCTest coverage for PendingAnalysis.
// All tests use an in-memory ModelContainer to avoid touching the file system.

import XCTest
import SwiftData
@testable import Bin_Brain

final class PendingAnalysisTests: XCTestCase {

    // MARK: - Setup

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([PendingUpload.self, PendingAnalysis.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - Test 1: Default Initialisation

    func testDefaultInitialisationSetsExpectedValues() throws {
        let before = Date()
        let analysis = PendingAnalysis(photoId: 7, binId: "BIN-0042")
        let after = Date()

        XCTAssertEqual(analysis.photoId, 7)
        XCTAssertEqual(analysis.binId, "BIN-0042")
        XCTAssertEqual(analysis.retryCount, 0)
        XCTAssertGreaterThanOrEqual(analysis.interruptedAt, before)
        XCTAssertLessThanOrEqual(analysis.interruptedAt, after)
    }

    // MARK: - Test 2: Persist and Fetch

    func testPersistAndFetchRoundTrip() throws {
        let analysis = PendingAnalysis(photoId: 42, binId: "BIN-0007")
        context.insert(analysis)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PendingAnalysis>())
        XCTAssertEqual(fetched.count, 1)
        let item = try XCTUnwrap(fetched.first)
        XCTAssertEqual(item.photoId, 42)
        XCTAssertEqual(item.binId, "BIN-0007")
        XCTAssertEqual(item.retryCount, 0)
    }

    // MARK: - Test 3: RetryCount Increment

    func testRetryCountIncrements() {
        let analysis = PendingAnalysis(photoId: 1, binId: "BIN-0001")

        XCTAssertEqual(analysis.retryCount, 0)
        analysis.retryCount += 1
        XCTAssertEqual(analysis.retryCount, 1)
        analysis.retryCount += 1
        XCTAssertEqual(analysis.retryCount, 2)
    }

    // MARK: - Test 4: Multiple Entries

    func testMultipleEntriesForDifferentPhotos() throws {
        let analysis1 = PendingAnalysis(photoId: 10, binId: "BIN-0001")
        let analysis2 = PendingAnalysis(photoId: 20, binId: "BIN-0002")
        context.insert(analysis1)
        context.insert(analysis2)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PendingAnalysis>())
        XCTAssertEqual(fetched.count, 2)
        let photoIds = Set(fetched.map(\.photoId))
        XCTAssertEqual(photoIds, Set([10, 20]))
    }

    // MARK: - Test 5: Delete

    func testDeleteRemovesEntryFromStore() throws {
        let analysis = PendingAnalysis(photoId: 99, binId: "BIN-0099")
        context.insert(analysis)
        try context.save()

        // Verify it was inserted.
        let beforeDelete = try context.fetch(FetchDescriptor<PendingAnalysis>())
        XCTAssertEqual(beforeDelete.count, 1)

        // Delete and save.
        context.delete(analysis)
        try context.save()

        // Verify deletion.
        let afterDelete = try context.fetch(FetchDescriptor<PendingAnalysis>())
        XCTAssertTrue(afterDelete.isEmpty)
    }
}
