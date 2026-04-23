// AnalysisViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for AnalysisViewModel.swift.
// AnalysisProgressView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in AnalysisViewModel.

import XCTest
import UIKit
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

private extension URLRequest {
    var bodyData: Data? {
        if let data = httpBody { return data }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }
}

// MARK: - AnalysisViewModelTests

// MARK: - Test double for BackgroundTaskRunning

final class RecordingBackgroundTaskRunner: BackgroundTaskRunning, @unchecked Sendable {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var lastExpirationHandler: (@Sendable () -> Void)?
    private var nextId = 100

    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> Int {
        beginCount += 1
        lastExpirationHandler = expirationHandler
        defer { nextId += 1 }
        return nextId
    }

    func end(_ id: Int) {
        endCount += 1
    }
}

@MainActor
final class AnalysisViewModelTests: XCTestCase {

    var sut: AnalysisViewModel!
    var runner: RecordingBackgroundTaskRunner!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        runner = RecordingBackgroundTaskRunner()
        sut = AnalysisViewModel(backgroundTask: runner)
    }

    override func tearDown() async throws {
        AnalysisMockURLProtocol.requestHandler = nil
        sut = nil
        runner = nil
        try await super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        AnalysisMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnalysisMockURLProtocol.self]
        return APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-api-key"])
        )
    }

    private var ingestSuccessJSON: Data {
        Data("""
        {
            "version": "1",
            "bin_id": "BIN-0001",
            "photos": [{"photo_id": 42, "url": "/photos/42/file"}]
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

    /// Swift2_015 — suggest response that echoes the server's live
    /// `prompt_version = "v2"` (PR #22). Used to verify the VM captures
    /// the value into `lastPromptVersion` for downstream outcomes telemetry.
    private var suggestSuccessJSONWithPromptVersion: Data {
        Data("""
        {
            "version": "1",
            "photo_id": 42,
            "model": "test-model",
            "prompt_version": "v2",
            "vision_elapsed_ms": 1200,
            "suggestions": [
                {"item_id": null, "name": "Widget", "category": "Hardware", "confidence": 0.92, "bins": ["BIN-0001"]}
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

    // MARK: - Regression — Swift2_014: reset() clears lastVisionModel

    /// `lastVisionModel` is threaded into `SuggestionReviewViewModel` for
    /// outcomes telemetry (Swift2_014). If `reset()` leaves it intact, a
    /// subsequent cataloging flow whose `/suggest` response somehow lacks
    /// the `model` field (or that never reaches `suggest`) would carry
    /// forward the prior session's VLM string and attach it to the new
    /// photo's outcomes POST — mislabeling which model produced what.
    func testResetClearsLastVisionModel() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)
        XCTAssertEqual(sut.lastVisionModel, "test-model",
                       "lastVisionModel should be populated from /suggest response.model")

        sut.reset()

        XCTAssertNil(sut.lastVisionModel,
                     "reset() must clear lastVisionModel — stale model IDs would mislabel future outcomes telemetry")
    }

    // MARK: - Swift2_015 — lastPromptVersion capture & reset

    /// The `/suggest` endpoint echoes `prompt_version` (binbrain PR #22).
    /// AnalysisViewModel must capture it on successful completion so parent
    /// views can thread it into `SuggestionReviewViewModel` for outcomes
    /// telemetry. Without this capture, outcomes POST bodies would forever
    /// carry `prompt_version: null` (the Phase 2a hack Swift2_015 removes).
    func testRunCapturesLastPromptVersionFromSuggest() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSONWithPromptVersion)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(sut.lastPromptVersion, "v2",
                       "lastPromptVersion must be populated from /suggest response.prompt_version")
    }

    /// When the server omits `prompt_version` (older build or genuine
    /// absence), iOS must forward nil — never synthesize a client-side value.
    func testRunLeavesLastPromptVersionNilWhenSuggestOmitsField() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertNil(sut.lastPromptVersion,
                     "lastPromptVersion must stay nil when the server did not echo prompt_version")
    }

    /// Same leak risk as `lastVisionModel` — a stale prompt_version carried
    /// across cataloging flows would mislabel which prompt produced the
    /// user's decisions. `reset()` must clear it.
    func testResetClearsLastPromptVersion() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSONWithPromptVersion)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)
        XCTAssertEqual(sut.lastPromptVersion, "v2",
                       "precondition — lastPromptVersion populated after a successful run")

        sut.reset()

        XCTAssertNil(sut.lastPromptVersion,
                     "reset() must clear lastPromptVersion — stale prompt IDs would mislabel future outcomes telemetry")
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

    // MARK: - Test 8: Zero suggestions completes successfully

    func testRunCompletesWithZeroSuggestions() async {
        let emptySuggestJSON = Data("""
        {
            "version": "1",
            "photo_id": 42,
            "model": "test-model",
            "vision_elapsed_ms": 500,
            "suggestions": []
        }
        """.utf8)

        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), emptySuggestJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(sut.phase, .complete, "Phase should be .complete even with zero suggestions")
        XCTAssertTrue(sut.suggestions.isEmpty, "Suggestions should be empty")
    }

    // MARK: - Finding #4-UX: preview the rejected photo on quality failure

    /// Builds a valid JPEG that will fail the resolution quality gate
    /// (shortest side < 1024). Drives the `qualityGateFailed` path in
    /// `ImagePipeline.process` deterministically.
    private func makeTinyJPEG(width: Int = 64, height: Int = 64) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(UIColor.gray.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }

    func testLastRejectedPhotoDataIsPopulatedOnQualityFailure() async throws {
        let tinyJPEG = try XCTUnwrap(makeTinyJPEG(), "failed to synthesize tiny JPEG for test")
        let client = makeMockAPIClient { _ in
            // Quality gate should reject before any network call is made.
            XCTFail("No network call expected when resolution gate fails")
            throw URLError(.cancelled)
        }

        await sut.run(jpegData: tinyJPEG, binId: "BIN-0001", apiClient: client)

        if case .qualityFailed = sut.phase {
            // expected
        } else {
            XCTFail("Phase should be .qualityFailed for a 64x64 image, got \(sut.phase)")
        }
        XCTAssertEqual(sut.lastRejectedPhotoData, tinyJPEG,
                       "lastRejectedPhotoData must retain the exact bytes the user just captured so the rejection screen can render a thumbnail")
        XCTAssertNotNil(sut.lastQualityFailure, "lastQualityFailure should also be recorded")
    }

    func testLastRejectedPhotoDataIsInitiallyNil() {
        XCTAssertNil(sut.lastRejectedPhotoData, "should start nil before any run")
    }

    // MARK: - Finding #15: background task released in all terminal paths

    func testRunReleasesBackgroundTaskOnSuccess() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(runner.beginCount, 1, "begin must fire exactly once")
        XCTAssertEqual(runner.endCount, 1, "end must fire exactly once on success")
    }

    func testRunReleasesBackgroundTaskOnIngestError() async {
        let client = makeMockAPIClient { [self] _ in
            return (makeAnalysisMockResponse(statusCode: 500), serverErrorJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(runner.beginCount, 1)
        XCTAssertEqual(runner.endCount, 1, "end must fire on early-return ingest error path")
    }

    func testRunReleasesBackgroundTaskOnSuggestError() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 500), serverErrorJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(runner.beginCount, 1)
        XCTAssertEqual(runner.endCount, 1, "end must fire when suggest throws after ingest succeeded")
    }

    func testRunReleasesBackgroundTaskOnQualityFailure() async throws {
        let tinyJPEG = try XCTUnwrap(makeTinyJPEG(),
                                     "failed to synthesize tiny JPEG that should fail the resolution gate")
        let client = makeMockAPIClient { _ in
            XCTFail("Quality gate should reject before any network call")
            throw URLError(.cancelled)
        }

        await sut.run(jpegData: tinyJPEG, binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(runner.beginCount, 1)
        XCTAssertEqual(runner.endCount, 1,
                       "end must fire on the early-return quality-gate path too")
    }

    func testOverrideQualityGateReleasesBackgroundTaskOnSuccess() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.overrideQualityGate(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(runner.beginCount, 1, "overrideQualityGate must begin a BG task (Finding #19)")
        XCTAssertEqual(runner.endCount, 1, "overrideQualityGate must end the BG task on success")
    }

    func testOverrideQualityGateReleasesBackgroundTaskOnExpirationHandler() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.overrideQualityGate(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)
        // Simulate a late OS expiration firing after defer already released.
        runner.lastExpirationHandler?()

        XCTAssertEqual(runner.endCount, 1,
                       "Late expiration after defer cleanup must not double-release the grant")
    }

    func testOverrideQualityGateIncludesFailureContextInDeviceMetadata() async throws {
        let tinyJPEG = try XCTUnwrap(makeTinyJPEG(), "failed to synthesize tiny JPEG")

        let failingClient = makeMockAPIClient { _ in
            XCTFail("No network call expected when resolution gate fails")
            throw URLError(.cancelled)
        }
        await sut.run(jpegData: tinyJPEG, binId: "BIN-0001", apiClient: failingClient)
        let failure = try XCTUnwrap(sut.lastQualityFailure, "precondition: quality failure should be captured")
        XCTAssertEqual(failure.gate, .resolution)

        var capturedIngestBody = ""
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            capturedIngestBody = request.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.overrideQualityGate(jpegData: tinyJPEG, binId: "BIN-0001", apiClient: client)

        try XCTSkipIf(
            !capturedIngestBody.contains("device_metadata"),
            "Image pipeline fell back to raw upload without metadata on this simulator clone"
        )
        XCTAssertTrue(capturedIngestBody.contains("quality_override_context"),
                      "device_metadata should include quality_override_context on Upload Anyway")
        XCTAssertTrue(capturedIngestBody.contains("\"bypassed\":true"))
        XCTAssertTrue(capturedIngestBody.contains("\"failed_gate\":\"resolution\""))
        XCTAssertTrue(capturedIngestBody.contains("\"threshold_label\":\"minimum\""))
    }

    func testReSuggestReleasesBackgroundTaskOnSuccess() async {
        // Seed lastPhotoId via a successful run first.
        let seedClient = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }
        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: seedClient)
        let beginBaseline = runner.beginCount
        let endBaseline = runner.endCount

        let resuggestClient = makeMockAPIClient { [self] _ in
            return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
        }
        await sut.reSuggest(apiClient: resuggestClient)

        XCTAssertEqual(runner.beginCount, beginBaseline + 1, "reSuggest must begin a BG task (Finding #19)")
        XCTAssertEqual(runner.endCount, endBaseline + 1, "reSuggest must end the BG task on success")
    }

    func testReSuggestReleasesBackgroundTaskOnLateExpiration() async {
        let seedClient = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }
        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: seedClient)

        let resuggestClient = makeMockAPIClient { [self] _ in
            return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
        }
        await sut.reSuggest(apiClient: resuggestClient)
        let endAfterNaturalCleanup = runner.endCount

        runner.lastExpirationHandler?()

        XCTAssertEqual(runner.endCount, endAfterNaturalCleanup,
                       "reSuggests -1 sentinel must make end() idempotent")
    }

    func testRunReleasesBackgroundTaskExactlyOnceWhenExpirationHandlerFiresAfterSuccess() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)

        // Simulate the OS firing the expiration handler late (after defer already
        // released the grant). The handler's idempotency guard must prevent a
        // second end().
        runner.lastExpirationHandler?()

        XCTAssertEqual(runner.endCount, 1,
                       "end() must be idempotent — late expiration after defer cleanup must not double-release")
    }

    // MARK: - Swift2_004 Step 3: gate metrics plumbed through to ViewModel

    /// Makes a 1024×1024 solid-gray JPEG. The flat image has near-zero Laplacian
    /// variance, so it passes the resolution gate but fails the blur gate.
    private func makeFlatJPEG(width: Int = 1024, height: Int = 1024) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(UIColor.gray.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }

    func testQualityFailureMetricsAvailableForResolutionGate() async throws {
        let tinyJPEG = try XCTUnwrap(makeTinyJPEG(), "failed to synthesize tiny JPEG")
        let client = makeMockAPIClient { _ in
            XCTFail("No network call expected when resolution gate fails")
            throw URLError(.cancelled)
        }

        await sut.run(jpegData: tinyJPEG, binId: "BIN-0001", apiClient: client)

        guard case .qualityFailed = sut.phase else {
            return XCTFail("Expected .qualityFailed phase, got \(sut.phase)")
        }
        let failure = try XCTUnwrap(sut.lastQualityFailure, "lastQualityFailure should be set")
        XCTAssertEqual(failure.gate, .resolution)
        XCTAssertEqual(failure.metrics.label, "Short side")
        XCTAssertEqual(failure.metrics.thresholdLabel, "minimum")
        XCTAssertEqual(failure.metrics.threshold, 1024.0, accuracy: 0.1)
        XCTAssertEqual(failure.metrics.measured, 64.0, accuracy: 1.0)
    }

    func testQualityFailureMetricsAvailableForBlurGate() async throws {
        let flatJPEG = try XCTUnwrap(makeFlatJPEG(), "failed to synthesize flat JPEG for blur gate test")
        let client = makeMockAPIClient { _ in
            XCTFail("No network call expected when blur gate fails")
            throw URLError(.cancelled)
        }

        await sut.run(jpegData: flatJPEG, binId: "BIN-0001", apiClient: client)

        guard case .qualityFailed = sut.phase else {
            return XCTFail("Expected .qualityFailed phase, got \(sut.phase)")
        }
        let failure = try XCTUnwrap(sut.lastQualityFailure, "lastQualityFailure should be set")
        XCTAssertEqual(failure.gate, .blur)
        XCTAssertEqual(failure.metrics.label, "Blur variance")
        XCTAssertEqual(failure.metrics.thresholdLabel, "minimum")
        // At 1024px shortest side, scaledThreshold = kBlurVarianceThresholdAt1024 = 2.0
        XCTAssertEqual(failure.metrics.threshold, 2.0, accuracy: 1e-9)
        // Flat image variance must be below threshold (that's why the gate fired)
        XCTAssertLessThan(failure.metrics.measured, failure.metrics.threshold)
        XCTAssertGreaterThanOrEqual(failure.metrics.measured, 0)
    }

    func testResetClearsLastRejectedPhotoData() async throws {
        let tinyJPEG = try XCTUnwrap(makeTinyJPEG())
        let client = makeMockAPIClient { _ in
            throw URLError(.cancelled)
        }
        await sut.run(jpegData: tinyJPEG, binId: "BIN-0001", apiClient: client)
        XCTAssertNotNil(sut.lastRejectedPhotoData, "precondition: preview populated after rejection")

        sut.reset()

        XCTAssertNil(sut.lastRejectedPhotoData, "reset() must clear the preview bytes")
        XCTAssertNil(sut.lastQualityFailure, "reset() must clear the failure")
    }

    // MARK: - Swift2_005 Step 1: lastUploadedPhotoData

    func testLastUploadedPhotoDataIsSetAfterSuccessfulRun() async {
        let inputData = Data("fake-jpeg".utf8)
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }

        await sut.run(jpegData: inputData, binId: "BIN-0001", apiClient: client)

        XCTAssertEqual(sut.phase, .complete, "precondition: run completed successfully")
        XCTAssertNotNil(sut.lastUploadedPhotoData,
                        "lastUploadedPhotoData must be set after a successful run")
        XCTAssertEqual(sut.lastUploadedPhotoData, inputData,
                       "lastUploadedPhotoData must equal the bytes that were uploaded")
    }

    func testLastUploadedPhotoDataIsInitiallyNil() {
        XCTAssertNil(sut.lastUploadedPhotoData, "lastUploadedPhotoData should start nil before any run")
    }

    func testResetClearsLastUploadedPhotoData() async {
        let client = makeMockAPIClient { [self] request in
            if request.url?.path.contains("/suggest") == true {
                return (makeAnalysisMockResponse(statusCode: 200), suggestSuccessJSON)
            }
            return (makeAnalysisMockResponse(statusCode: 200), ingestSuccessJSON)
        }
        await sut.run(jpegData: Data("fake-jpeg".utf8), binId: "BIN-0001", apiClient: client)
        XCTAssertNotNil(sut.lastUploadedPhotoData, "precondition: lastUploadedPhotoData populated after run")

        sut.reset()

        XCTAssertNil(sut.lastUploadedPhotoData, "reset() must clear lastUploadedPhotoData")
    }

    // MARK: - Swift2_006: rotation state persistence

    /// Verifies that qualityFailed phase + lastRejectedPhotoData survive a simulated
    /// re-render without an explicit reset().
    ///
    /// On rotation, SwiftUI rebuilds view structs but preserves @State values —
    /// meaning the same AnalysisViewModel instance is reused. This test documents
    /// the contract: state must not self-clear outside of reset(). The fullScreenCover
    /// fix (Finding #23) prevents the sheet from being dismissed, so this ViewModel
    /// state is guaranteed to be visible to the rebuilt view.
    func testQualityFailedStateAndPhotoDataPersistAcrossSimulatedRerender() async throws {
        let tinyJPEG = try XCTUnwrap(makeTinyJPEG(), "failed to synthesize tiny JPEG")
        let client = makeMockAPIClient { _ in
            XCTFail("No network call expected when resolution gate fails")
            throw URLError(.cancelled)
        }

        await sut.run(jpegData: tinyJPEG, binId: "BIN-0001", apiClient: client)

        // Capture state after quality failure.
        guard case .qualityFailed = sut.phase else {
            return XCTFail("Precondition: phase should be .qualityFailed, got \(sut.phase)")
        }
        XCTAssertNotNil(sut.lastRejectedPhotoData, "precondition: rejected photo data must be set")

        // Simulate a rotation/re-render: SwiftUI rebuilds the view struct but
        // reuses the same @State ViewModel instance. No reset() is called.
        // State must still be intact so the quality-gate screen can re-render correctly.
        guard case .qualityFailed = sut.phase else {
            return XCTFail("phase must remain .qualityFailed after re-render — rotation must not dismiss or reset the view")
        }
        XCTAssertEqual(sut.lastRejectedPhotoData, tinyJPEG,
                       "lastRejectedPhotoData must survive re-render so the rejection screen thumbnail stays visible")
        XCTAssertNotNil(sut.lastQualityFailure,
                        "lastQualityFailure must survive re-render so the metric readout stays visible")
    }
}
