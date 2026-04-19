// PendingOutcomeTests.swift
// Bin BrainTests
//
// SwiftData CRUD coverage for the Swift2_018 offline-outcomes queue model.
// All tests use an in-memory ModelContainer to avoid touching the file
// system or any device state.

import XCTest
import SwiftData
@testable import Bin_Brain

final class PendingOutcomeTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([PendingOutcome.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - Defaults

    func testDefaultInitialisationSetsExpectedValues() {
        let before = Date()
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let row = PendingOutcome(photoId: 42, payload: payload)
        let after = Date()

        XCTAssertEqual(row.photoId, 42)
        XCTAssertEqual(row.payload, payload)
        XCTAssertEqual(row.retryCount, 0)
        XCTAssertEqual(row.status, .pending)
        XCTAssertNil(row.lastErrorCode)
        XCTAssertGreaterThanOrEqual(row.queuedAt, before)
        XCTAssertLessThanOrEqual(row.queuedAt, after)
        XCTAssertEqual(row.nextRetryAt, row.queuedAt,
                       "First attempt has no backoff — nextRetryAt mirrors queuedAt")
    }

    // MARK: - UUID uniqueness

    func testIdsAreUniquePerInstance() {
        let a = PendingOutcome(photoId: 1, payload: Data([0]))
        let b = PendingOutcome(photoId: 2, payload: Data([1]))
        XCTAssertNotEqual(a.id, b.id, "Two constructed rows must have distinct client-side UUIDs")
    }

    // MARK: - Persistence

    func testRowSurvivesInsertAndFetch() throws {
        let row = PendingOutcome(photoId: 7, payload: Data([0xCA, 0xFE]))
        context.insert(row)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.photoId, 7)
        XCTAssertEqual(fetched.first?.status, .pending)
    }

    // MARK: - Status transitions

    func testStatusTransitionsThroughLifecycle() {
        let row = PendingOutcome(photoId: 1, payload: Data([0]))
        XCTAssertEqual(row.status, .pending)

        row.status = .sending
        XCTAssertEqual(row.status, .sending)

        row.status = .delivered
        XCTAssertEqual(row.status, .delivered)
    }

    func testStatusExpiredIsTerminal() {
        let row = PendingOutcome(photoId: 1, payload: Data([0]))
        row.status = .expired
        XCTAssertEqual(row.status, .expired)
    }

    // MARK: - Backoff math (pure function on the manager)

    func testBackoffStartsAt30Seconds() {
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 1), 30)
    }

    func testBackoffDoublesPerRetry() {
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 2), 60)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 3), 120)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 4), 240)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 5), 480)
    }

    func testBackoffCapsAtOneHour() {
        // 30 * 2^(n-1): crosses 3600s between retry 7 (1920) and retry 8 (3840).
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 7), 1920)
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 8), 3600,
                       "Backoff must clamp at 1h regardless of retry count")
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 20), 3600,
                       "20th retry must still clamp at 1h — no overflow")
    }

    func testBackoffZeroOrNegativeReturnsImmediate() {
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: 0), 0,
                       "retryCount=0 means first attempt; no backoff required")
        XCTAssertEqual(OutcomeQueueManager.backoff(retryCount: -1), 0,
                       "Negative retryCount defends against corrupt persistence")
    }
}
