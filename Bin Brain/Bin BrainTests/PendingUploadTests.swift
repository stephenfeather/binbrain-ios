// PendingUploadTests.swift
// Bin BrainTests
//
// XCTest coverage for PendingUpload and UploadStatus.
// All tests use an in-memory ModelContainer to avoid touching the file system.

import XCTest
import SwiftData
@testable import Bin_Brain

final class PendingUploadTests: XCTestCase {

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
        let upload = PendingUpload(jpegData: Data([0xFF, 0xD8]), binId: "BIN-0001")
        let after = Date()

        XCTAssertEqual(upload.binId, "BIN-0001")
        XCTAssertEqual(upload.jpegData, Data([0xFF, 0xD8]))
        XCTAssertEqual(upload.retryCount, 0)
        XCTAssertEqual(upload.status, .pending)
        XCTAssertGreaterThanOrEqual(upload.queuedAt, before)
        XCTAssertLessThanOrEqual(upload.queuedAt, after)
    }

    // MARK: - Test 2: Status Mutation

    func testStatusTransitionsThroughLifecycle() {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")

        XCTAssertEqual(upload.status, .pending)

        upload.status = .uploading
        XCTAssertEqual(upload.status, .uploading)

        upload.status = .failed
        XCTAssertEqual(upload.status, .failed)

        // Can reset back to pending for a retry scenario.
        upload.status = .pending
        XCTAssertEqual(upload.status, .pending)
    }

    // MARK: - Test 3: RetryCount Increment

    func testRetryCountIncrements() {
        let upload = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")

        XCTAssertEqual(upload.retryCount, 0)
        upload.retryCount += 1
        XCTAssertEqual(upload.retryCount, 1)
        upload.retryCount += 1
        XCTAssertEqual(upload.retryCount, 2)
        upload.retryCount += 1
        XCTAssertEqual(upload.retryCount, 3)
    }

    // MARK: - Test 4: Persist and Fetch

    func testPersistAndFetchRoundTrip() throws {
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let upload = PendingUpload(jpegData: jpegData, binId: "BIN-0042")
        context.insert(upload)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(fetched.count, 1)
        let item = try XCTUnwrap(fetched.first)
        XCTAssertEqual(item.binId, "BIN-0042")
        XCTAssertEqual(item.jpegData, jpegData)
        XCTAssertEqual(item.retryCount, 0)
        XCTAssertEqual(item.status, .pending)
    }

    // MARK: - Test 5: Multiple Items

    func testMultipleItemsAllPersistAndFetch() throws {
        let binIds = ["BIN-0001", "BIN-0002", "BIN-0003"]
        for binId in binIds {
            context.insert(PendingUpload(jpegData: Data([0x01]), binId: binId))
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PendingUpload>())
        XCTAssertEqual(fetched.count, 3)
        let fetchedBinIds = Set(fetched.map(\.binId))
        XCTAssertEqual(fetchedBinIds, Set(binIds))
    }

    // MARK: - Test 6: Filter by Status

    func testFilterByStatusReturnsCorrectSubset() throws {
        let pending1 = PendingUpload(jpegData: Data([0x01]), binId: "BIN-0001")
        let pending2 = PendingUpload(jpegData: Data([0x02]), binId: "BIN-0002")
        let failed = PendingUpload(jpegData: Data([0x03]), binId: "BIN-0003")
        failed.status = .failed

        context.insert(pending1)
        context.insert(pending2)
        context.insert(failed)
        try context.save()

        let all = try context.fetch(FetchDescriptor<PendingUpload>())
        let pendingItems = all.filter { $0.status == .pending }
        let failedItems = all.filter { $0.status == .failed }

        XCTAssertEqual(pendingItems.count, 2)
        XCTAssertEqual(failedItems.count, 1)
        let failedItem = try XCTUnwrap(failedItems.first)
        XCTAssertEqual(failedItem.binId, "BIN-0003")
    }

    // MARK: - Test 7: UploadStatus Raw Values

    func testUploadStatusRawValues() {
        XCTAssertEqual(UploadStatus.pending.rawValue, "pending")
        XCTAssertEqual(UploadStatus.uploading.rawValue, "uploading")
        XCTAssertEqual(UploadStatus.failed.rawValue, "failed")
    }

    func testUploadStatusInitialisesFromRawValue() {
        XCTAssertEqual(UploadStatus(rawValue: "pending"), .pending)
        XCTAssertEqual(UploadStatus(rawValue: "uploading"), .uploading)
        XCTAssertEqual(UploadStatus(rawValue: "failed"), .failed)
        XCTAssertNil(UploadStatus(rawValue: "unknown"))
    }
}
