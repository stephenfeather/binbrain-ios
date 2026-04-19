// AnalysisViewModelSessionRecoveryTests.swift
// Bin BrainTests
//
// Swift2_019b — F-1 / SEC-24-1. When the server returns
// 400 invalid_session on /ingest, AnalysisViewModel must:
//   1. Invalidate the stale cached Session on the SessionManager.
//   2. Ask the SessionManager for a fresh session (auto-begin).
//   3. Retry /ingest once with the new session id.
// Without the fix, the cached session stays populated and every
// subsequent ingest loops on 400s until the 30-min idle timer or an
// app restart.

import XCTest
@testable import Bin_Brain

// MARK: - URLProtocol (distinct per suite)

final class SessionRecoveryMockURLProtocol: URLProtocol {
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        handlerLock.lock(); defer { handlerLock.unlock() }
        _handler = handler
    }

    static func currentHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        handlerLock.lock(); defer { handlerLock.unlock() }
        return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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

@MainActor
final class AnalysisViewModelSessionRecoveryTests: XCTestCase {

    var sut: AnalysisViewModel!
    var sessionManager: SessionManager!
    var runner: RecordingBackgroundTaskRunner!

    override func setUp() async throws {
        try await super.setUp()
        runner = RecordingBackgroundTaskRunner()
        sut = AnalysisViewModel(backgroundTask: runner)
        sessionManager = SessionManager()
    }

    override func tearDown() async throws {
        SessionRecoveryMockURLProtocol.setHandler(nil)
        sessionManager.cancelIdleTimer()
        sessionManager = nil
        sut = nil
        runner = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        SessionRecoveryMockURLProtocol.setHandler(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionRecoveryMockURLProtocol.self]
        return APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-key"])
        )
    }

    private func response(_ code: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: code,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func sessionJSON(_ id: UUID) -> Data {
        Data("""
        {"session_id":"\(id.uuidString.lowercased())",
         "started_at":"2026-04-19T12:00:00Z","ended_at":null,
         "label":null,"photo_count":0}
        """.utf8)
    }

    private let invalidSessionErrorJSON = Data("""
    {"version":"1","error":{"code":"invalid_session",
     "message":"Session not found, not yours, or already closed"}}
    """.utf8)

    private let ingestSuccessJSON = Data("""
    {"version":"1","bin_id":"BIN-0001","photos":[{"photo_id":42,"url":"/photos/42/file"}]}
    """.utf8)

    private let suggestSuccessJSON = Data("""
    {"version":"1","photo_id":42,"model":"test-model","vision_elapsed_ms":50,
     "suggestions":[{"item_id":null,"name":"Widget","category":"Hardware","confidence":0.9,"bins":["BIN-0001"]}]}
    """.utf8)

    // MARK: - Recovery path

    /// The server rotates/restarts/idles-away the cached session. Next
    /// ingest gets 400 `invalid_session`. The VM must invalidate, auto-begin
    /// a fresh session, and retry once — transparently to the user.
    func testRunInvalidSessionResponseInvalidatesAndRetriesOnceWithFreshSession() async throws {
        let staleId = UUID()
        let freshId = UUID()

        // Phase 1 — seed the SessionManager with a stale session. Install
        // the seed handler FIRST and tear it down before the scenario
        // handler is installed. The URL protocol has a single static
        // handler slot; installing a new one replaces the last.
        sessionManager = SessionManager()
        let seedClient = makeClient { [self] request in
            if request.httpMethod == "POST", request.url?.path == "/sessions" {
                return (response(201, for: request), sessionJSON(staleId))
            }
            return (response(500, for: request), Data())
        }
        _ = try await sessionManager.beginSession(apiClient: seedClient)
        XCTAssertEqual(sessionManager.current?.id, staleId, "precondition: stale session cached")

        // Phase 2 — install the scenario handler AFTER the seed completes.
        var ingestCount = 0
        var firstAttemptRetryHeader: String?
        var retryAttemptRetryHeader: String?
        var retrySessionField: String?
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                return (response(201, for: request), sessionJSON(freshId))
            }
            if path == "/ingest" {
                ingestCount += 1
                if ingestCount == 1 {
                    firstAttemptRetryHeader = request.value(forHTTPHeaderField: "X-Client-Retry-Count")
                    return (response(400, for: request), invalidSessionErrorJSON)
                }
                retryAttemptRetryHeader = request.value(forHTTPHeaderField: "X-Client-Retry-Count")
                if let body = request.bodyData,
                   let s = String(data: body, encoding: .utf8) {
                    // Multipart field; substring match is fine since the
                    // body was constructed by our own APIClient.
                    retrySessionField = s.components(separatedBy: "session_id\"\r\n\r\n")
                        .dropFirst().first?.prefix(36).description
                }
                return (response(200, for: request), ingestSuccessJSON)
            }
            if path.hasSuffix("/suggest") {
                return (response(200, for: request), suggestSuccessJSON)
            }
            return (response(500, for: request), Data())
        }

        await sut.run(
            jpegData: Data("fake-jpeg".utf8),
            binId: "BIN-0001",
            apiClient: client,
            sessionId: staleId,
            sessionManager: sessionManager
        )

        XCTAssertEqual(ingestCount, 2,
                       "VM must retry /ingest exactly once after invalid_session")
        XCTAssertNotNil(sessionManager.current,
                        "Fresh session must be auto-begun after invalidation")
        XCTAssertEqual(sessionManager.current?.id, freshId,
                       "Retry must use the freshly-minted session, not the stale one")
        XCTAssertEqual(sut.phase, .complete,
                       "After successful retry, phase must land on .complete")

        // Swift2_019c G-2 / SEC-25-3 — assert the retry body actually
        // carries freshId, not staleId. Activates the previously-unused
        // bodyData helper. A typo regression like `sessionId: staleId`
        // would leave this assertion failing even though the mock-200
        // round-trip would otherwise pass.
        XCTAssertEqual(retrySessionField, freshId.uuidString.lowercased(),
                       "Retry /ingest must carry the freshly-minted session_id, not the stale one")
        XCTAssertNotEqual(retrySessionField, staleId.uuidString.lowercased(),
                          "Retry /ingest must NOT reuse the stale session_id")

        // Swift2_019c SEC-25-4 — header is observational only but the
        // first attempt MUST NOT carry it (so server telemetry can
        // distinguish "user's first try" from "client-driven recovery").
        XCTAssertNil(firstAttemptRetryHeader,
                     "X-Client-Retry-Count must be absent on the first attempt")
        XCTAssertEqual(retryAttemptRetryHeader, "1",
                       "X-Client-Retry-Count: 1 must be stamped on the recovery retry")
    }

    /// Swift2_019b G-1 (PR #25 QA). A delayed `invalid_session` 400 for
    /// a stale in-flight request must not wipe out a newer legitimate
    /// session that the manager has since advanced to. The recovery
    /// path now passes `ifCurrentIs: sessionId`; `invalidateCurrentSession`
    /// no-ops when `current.id != sessionId`.
    func testRecoveryDoesNotClobberSessionThatChangedDuringIngest() async throws {
        let staleId = UUID()
        let newId = UUID()  // NOT the id the client is trying to ingest with

        let seedClient = makeClient { [self] request in
            if request.httpMethod == "POST", request.url?.path == "/sessions" {
                return (response(201, for: request), sessionJSON(newId))
            }
            return (response(500, for: request), Data())
        }
        // Seed the manager with `newId` — the CURRENT, legitimate session.
        _ = try await sessionManager.beginSession(apiClient: seedClient)
        XCTAssertEqual(sessionManager.current?.id, newId, "precondition")

        // Then fire an /ingest that references the STALE id (an in-flight
        // request from before the session flipped). Server returns
        // invalid_session for the stale id.
        var beganCount = 0
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                beganCount += 1
                return (response(201, for: request), sessionJSON(UUID()))
            }
            if path == "/ingest" {
                return (response(400, for: request), invalidSessionErrorJSON)
            }
            return (response(500, for: request), Data())
        }

        await sut.run(
            jpegData: Data("fake".utf8),
            binId: "BIN-0001",
            apiClient: client,
            sessionId: staleId,            // ← the in-flight uses the stale id
            sessionManager: sessionManager
        )

        XCTAssertEqual(sessionManager.current?.id, newId,
                       "Recovery must NOT clobber a session-manager session whose id "
                       + "differs from the id that the /ingest actually used")
        XCTAssertEqual(beganCount, 0,
                       "Recovery must not mint a new session when current has already "
                       + "advanced past the stale id")
    }

    /// If the retry also fails (e.g. server 500), surface the error
    /// normally. The VM must not loop indefinitely.
    func testRunInvalidSessionRetryFailureSurfacesError() async throws {
        let staleId = UUID()
        let freshId = UUID()

        // Seed first, install scenario handler second (per the ordering
        // bug fixed above — the URL protocol has only one handler slot).
        let seedClient = makeClient { [self] request in
            if request.httpMethod == "POST", request.url?.path == "/sessions" {
                return (response(201, for: request), sessionJSON(staleId))
            }
            return (response(500, for: request), Data())
        }
        _ = try await sessionManager.beginSession(apiClient: seedClient)

        var ingestCount = 0
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                return (response(201, for: request), sessionJSON(freshId))
            }
            if path == "/ingest" {
                ingestCount += 1
                if ingestCount == 1 {
                    return (response(400, for: request), invalidSessionErrorJSON)
                }
                // Second attempt also fails — different error so the VM
                // cannot loop on the invalidate-then-retry branch.
                return (response(500, for: request), Data())
            }
            return (response(500, for: request), Data())
        }

        await sut.run(
            jpegData: Data("fake-jpeg".utf8),
            binId: "BIN-0001",
            apiClient: client,
            sessionId: staleId,
            sessionManager: sessionManager
        )

        XCTAssertEqual(ingestCount, 2, "Must retry exactly once — no infinite loop")
        if case .failed = sut.phase {
            // expected
        } else {
            XCTFail("Retry failure must surface as .failed, got \(sut.phase)")
        }
    }

    // MARK: - Swift2_019c G-3 — retry-also-invalid_session must not loop

    /// Pin the single-retry bound when the retry itself also returns
    /// 400 `invalid_session`. The catch clause is not re-entrant, but a
    /// future regression that wrapped the retry in another do/catch could
    /// re-enter the recovery branch — this test would catch it.
    func testRunInvalidSessionRetryAlsoInvalidSessionDoesNotLoop() async throws {
        let staleId = UUID()
        let freshId = UUID()

        let seedClient = makeClient { [self] request in
            if request.httpMethod == "POST", request.url?.path == "/sessions" {
                return (response(201, for: request), sessionJSON(staleId))
            }
            return (response(500, for: request), Data())
        }
        _ = try await sessionManager.beginSession(apiClient: seedClient)

        var ingestCount = 0
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                return (response(201, for: request), sessionJSON(freshId))
            }
            if path == "/ingest" {
                ingestCount += 1
                return (response(400, for: request), invalidSessionErrorJSON)
            }
            return (response(500, for: request), Data())
        }

        await sut.run(
            jpegData: Data("fake".utf8),
            binId: "BIN-0001",
            apiClient: client,
            sessionId: staleId,
            sessionManager: sessionManager
        )

        XCTAssertEqual(ingestCount, 2,
                       "Single-retry bound must hold even when the retry itself is also invalid_session")
        if case .failed = sut.phase { /* ok */ } else {
            XCTFail("Retry-with-same-error must surface as .failed, got \(sut.phase)")
        }
    }

    // MARK: - Swift2_019c G-4 — overrideQualityGate recovery path

    /// Near-clone of testRunInvalidSessionResponse... but driving through
    /// `overrideQualityGate(...)` instead of `run(...)`. The recovery
    /// helper is shared/static, but the wiring from `overrideQualityGate`
    /// is independent of `run` and can regress on its own.
    func testOverrideQualityGateInvalidSessionResponseInvalidatesAndRetriesOnce() async throws {
        let staleId = UUID()
        let freshId = UUID()

        // Phase 1 — seed the SessionManager with a stale session.
        sessionManager = SessionManager()
        let seedClient = makeClient { [self] request in
            if request.httpMethod == "POST", request.url?.path == "/sessions" {
                return (response(201, for: request), sessionJSON(staleId))
            }
            return (response(500, for: request), Data())
        }
        _ = try await sessionManager.beginSession(apiClient: seedClient)
        XCTAssertEqual(sessionManager.current?.id, staleId, "precondition: stale session cached")

        // Phase 2 — install scenario handler.
        var ingestCount = 0
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                return (response(201, for: request), sessionJSON(freshId))
            }
            if path == "/ingest" {
                ingestCount += 1
                if ingestCount == 1 {
                    return (response(400, for: request), invalidSessionErrorJSON)
                }
                return (response(200, for: request), ingestSuccessJSON)
            }
            if path.hasSuffix("/suggest") {
                return (response(200, for: request), suggestSuccessJSON)
            }
            return (response(500, for: request), Data())
        }

        await sut.overrideQualityGate(
            jpegData: Data("fake-jpeg".utf8),
            binId: "BIN-0001",
            apiClient: client,
            sessionId: staleId,
            sessionManager: sessionManager
        )

        XCTAssertEqual(ingestCount, 2,
                       "overrideQualityGate must also retry /ingest exactly once after invalid_session")
        XCTAssertEqual(sessionManager.current?.id, freshId,
                       "Override path must use the freshly-minted session, not the stale one")
        XCTAssertEqual(sut.phase, .complete,
                       "After successful retry via override path, phase must land on .complete")
    }
}

// MARK: - URLRequest body helper (file-private)

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
