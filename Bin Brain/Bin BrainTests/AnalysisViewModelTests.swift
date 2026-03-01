// AnalysisViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for AnalysisViewModel.swift.
// AnalysisProgressView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in AnalysisViewModel.

import XCTest
@testable import Bin_Brain

// MARK: - AnalysisMockURLProtocol

/// A URLProtocol subclass that intercepts all requests for AnalysisViewModel tests.
///
/// Uses a distinct name from `MockURLProtocol` (defined in APIClientTests.swift)
/// to avoid symbol collision.
final class AnalysisMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = AnalysisMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeAnalysisMockResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://mock")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

// MARK: - AnalysisViewModelTests

final class AnalysisViewModelTests: XCTestCase {

    var sut: AnalysisViewModel!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = AnalysisViewModel()
    }

    override func tearDown() async throws {
        AnalysisMockURLProtocol.requestHandler = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        AnalysisMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnalysisMockURLProtocol.self]
        return APIClient(session: URLSession(configuration: config))
    }

    private var ingestSuccessJSON: Data {
        Data("""
        {
            "version": "1",
            "bin_id": "BIN-0001",
            "photos": [{"photo_id": 42, "path": "/photos/42.jpg"}]
        }
        """.utf8)
    }

    private var suggestSuccessJSON: Data {
        Data("""
        {
            "version": "1",
            "photo_id": 42,
            "model": "test-model",
            "vision_elapsed_ms": 1200,
            "suggestions": [
                {"item_id": null, "name": "Widget", "category": "Hardware", "confidence": 0.92, "bins": ["BIN-0001"]},
                {"item_id": 5, "name": "Bolt", "category": "Fasteners", "confidence": 0.78, "bins": ["BIN-0001", "BIN-0002"]}
            ]
        }
        """.utf8)
    }

    private var serverErrorJSON: Data {
        Data("""
        {"version": "1", "error": {"code": "server_error", "message": "Internal server error"}}
        """.utf8)
    }

    // MARK: - Test 1: Initial state

    func testInitialPhaseIsIdle() {
        XCTAssertEqual(sut.phase, .idle, "Fresh AnalysisViewModel should start in .idle phase")
        XCTAssertTrue(sut.suggestions.isEmpty, "suggestions should be empty on init")
    }

    // MARK: - Test 2: Successful run completes with suggestions

    func testRunCompletesWithSuggestions() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(sut.phase, .complete, "Phase should be .complete after successful run")
        XCTAssertEqual(sut.suggestions.count, 2, "Should have 2 suggestions")
        XCTAssertEqual(sut.suggestions[0].name, "Widget")
        XCTAssertEqual(sut.suggestions[1].name, "Bolt")
    }

    // MARK: - Test 3: Ingest failure transitions to .failed

    func testRunSetsFailedOnIngestError() async {
        let client = makeMockAPIClient { [self] _ in
            return (makeAnalysisMockResponse(statusCode: 500), serverErrorJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        if case .failed = sut.phase {
            // Correct: phase is .failed
        } else {
            XCTFail("Phase should be .failed after ingest error, got \(sut.phase)")
        }
        XCTAssertTrue(sut.suggestions.isEmpty, "Suggestions should remain empty after ingest error")
    }

    // MARK: - Test 4: Suggest failure transitions to .failed

    func testRunSetsFailedOnSuggestError() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 500), serverErrorJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        if case .failed = sut.phase {
            // Correct: phase is .failed
        } else {
            XCTFail("Phase should be .failed after suggest error, got \(sut.phase)")
        }
    }

    // MARK: - Test 5: reset() after .complete restores initial state

    func testResetRestoresInitialState() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)
        XCTAssertEqual(sut.phase, .complete)

        sut.reset()

        XCTAssertEqual(sut.phase, .idle, "reset() should restore phase to .idle")
        XCTAssertTrue(sut.suggestions.isEmpty, "reset() should clear suggestions")
    }

    // MARK: - Test 6: suggestions are cleared after reset

    func testSuggestionsAreEmptyAfterReset() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)
        XCTAssertEqual(sut.suggestions.count, 2, "Should have suggestions before reset")

        sut.reset()

        XCTAssertTrue(sut.suggestions.isEmpty, "Suggestions should be empty after reset")
    }

    // MARK: - Test 7: reset() from .failed state restores .uploading

    func testResetFromFailedStateRestoresUploading() async {
        let client = makeMockAPIClient { [self] _ in
            return (makeAnalysisMockResponse(statusCode: 500), serverErrorJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)
        if case .failed = sut.phase {
            // Expected — test proceeding
        } else {
            XCTFail("Phase should be .failed after error")
        }

        sut.reset()

        XCTAssertEqual(sut.phase, .idle, "reset() from .failed should restore phase to .idle")
        XCTAssertTrue(sut.suggestions.isEmpty, "Suggestions should be empty after reset from .failed")
    }
}
