// SuggestionReviewOutcomeQueueIntegrationTests.swift
// Bin BrainTests
//
// Swift2_018 — verifies that `SuggestionReviewViewModel.confirm()` routes
// the outcomes POST through `OutcomeQueueManager.enqueue(...)` when the
// view injects both the manager and a ModelContext. The pre-existing
// `PhotoSuggestionOutcomesTests` still cover the legacy fire-and-forget
// detached-Task path.

import XCTest
import SwiftData
@testable import Bin_Brain

@MainActor
final class SuggestionReviewOutcomeQueueIntegrationTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    var queue: OutcomeQueueManager!
    var sut: SuggestionReviewViewModel!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([PendingOutcome.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
        queue = OutcomeQueueManager()
        sut = SuggestionReviewViewModel()
        sut.threeStateEnabled = false // exercise the legacy outcomes path
        sut.outcomeQueueManager = queue
        sut.outcomeQueueContext = context
    }

    override func tearDown() async throws {
        OutcomeQueueMockURLProtocol.setHandler(nil)
        sut = nil
        queue = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        OutcomeQueueMockURLProtocol.setHandler(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutcomeQueueMockURLProtocol.self]
        return APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-key"])
        )
    }

    private func mockResponse(statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func makeSuggestions() throws -> [SuggestionItem] {
        let json = Data("""
        [
            {"item_id": null, "name": "Widget", "category": "Hardware", "confidence": 0.92, "bins": ["BIN-0001"]}
        ]
        """.utf8)
        return try JSONDecoder.binBrain.decode([SuggestionItem].self, from: json)
    }

    private var upsertSuccessJSON: Data {
        Data("""
        {"version":"1","item_id":101,"fingerprint":"widget|hardware","name":"Widget","category":"Hardware"}
        """.utf8)
    }

    private var associateSuccessJSON: Data {
        Data("""
        {"ok":true,"bin_id":"BIN-0001","item_id":101}
        """.utf8)
    }

    private var confirmClassSuccessJSON: Data {
        Data("""
        {"version":"1","class_name":"Widget","added":true,"active_class_count":47,"reload_triggered":true}
        """.utf8)
    }

    // MARK: - Success path persists a .delivered row

    func testConfirmEnqueuesAndDeliversWhenQueueInjected() async throws {
        sut.loadSuggestions(try makeSuggestions(),
                            photoId: 42,
                            visionModel: "vision-test",
                            promptVersion: nil)

        let outcomesHit = expectation(description: "/outcomes POST reached the mock")
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/outcomes") {
                outcomesHit.fulfill()
                return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
            }
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        // F-2 durability guarantee: the row MUST be in the store by the
        // time confirm() returns, with no async settling. An app-kill at
        // this moment must not drop the outcome.
        let rowsAtReturn = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(rowsAtReturn.count, 1,
                       "F-2: the PendingOutcome row must be durable the instant confirm() returns — no Task.sleep papering over races")
        XCTAssertEqual(rowsAtReturn.first?.photoId, 42)

        // Delivery itself is async; wait for the POST to land.
        await fulfillment(of: [outcomesHit], timeout: 2.0)

        // Give the delivery-branch `save` a chance to run, then re-fetch.
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        let rowsAfter = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(rowsAfter.first?.status, .delivered,
                       "2xx response must flip the persisted row to .delivered")
    }

    // MARK: - Failure path persists a .pending row for retry

    func testConfirmPersistsPendingRowWhenOutcomes500() async throws {
        sut.loadSuggestions(try makeSuggestions(),
                            photoId: 42,
                            visionModel: "vision-test",
                            promptVersion: nil)

        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/outcomes") {
                return (mockResponse(statusCode: 500, for: request), Data())
            }
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)

        // F-2: row durable synchronously.
        let rowsImmediate = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertEqual(rowsImmediate.count, 1,
                       "F-2: row must be durable at confirm() return even on the failure path")

        // Give the classify-and-save path a tick to land the 500 verdict.
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.status, .pending,
                       "5xx must leave the persisted row pending — NWPathMonitor / scenePhase sweep will retry")
        XCTAssertEqual(row.retryCount, 1)
        XCTAssertEqual(row.lastErrorCode, 500)
    }

    // MARK: - Guard: no queue injected → legacy path still works

    func testConfirmWithoutQueueInjectionUsesLegacyPath() async throws {
        // Drop the queue so the VM falls back to detached Task.
        sut.outcomeQueueManager = nil
        sut.outcomeQueueContext = nil

        sut.loadSuggestions(try makeSuggestions(),
                            photoId: 42,
                            visionModel: "vision-test",
                            promptVersion: nil)

        var outcomesHits = 0
        let client = makeMockAPIClient { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("/outcomes") {
                outcomesHits += 1
                return (mockResponse(statusCode: 200, for: request), Data("{}".utf8))
            }
            if path.contains("/classes/confirm") {
                return (mockResponse(statusCode: 200, for: request), confirmClassSuccessJSON)
            }
            if path.hasSuffix("/associate") {
                return (mockResponse(statusCode: 200, for: request), associateSuccessJSON)
            }
            return (mockResponse(statusCode: 200, for: request), upsertSuccessJSON)
        }

        await sut.confirm(binId: "BIN-0001", apiClient: client)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(outcomesHits, 1,
                       "Legacy fire-and-forget path must still send the outcomes POST exactly once")
        let rows = try context.fetch(FetchDescriptor<PendingOutcome>())
        XCTAssertTrue(rows.isEmpty,
                      "Legacy path must NOT touch the PendingOutcome store")
    }
}
