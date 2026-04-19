// SessionManagerTests.swift
// Bin BrainTests
//
// Swift2_019 — SessionManager drives the POST /sessions lifecycle,
// 30-min idle auto-close, and ingest auto-begin. Every test routes
// through URLProtocol mocks; no real sockets, no prod DB risk.

import XCTest
@testable import Bin_Brain

// MARK: - URLProtocol interceptor (distinct name per suite)

final class SessionMockURLProtocol: URLProtocol {
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
final class SessionManagerTests: XCTestCase {

    var sut: SessionManager!

    override func setUp() async throws {
        try await super.setUp()
        sut = SessionManager(idleTimeout: 30 * 60)
    }

    override func tearDown() async throws {
        SessionMockURLProtocol.setHandler(nil)
        sut.cancelIdleTimer()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        SessionMockURLProtocol.setHandler(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionMockURLProtocol.self]
        return APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-key"])
        )
    }

    private func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private let fixedSessionId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private var sessionJSON: Data {
        Data("""
        {
            "session_id": "11111111-2222-3333-4444-555555555555",
            "started_at": "2026-04-19T12:00:00Z",
            "ended_at": null,
            "label": null,
            "photo_count": 0
        }
        """.utf8)
    }

    // MARK: - beginSession

    func testBeginSessionPostsToSessionsAndStoresCurrent() async throws {
        var capturedMethod: String?
        var capturedPath: String?
        let client = makeClient { [self] request in
            capturedMethod = request.httpMethod
            capturedPath = request.url?.path
            return (response(201, for: request), sessionJSON)
        }

        let session = try await sut.beginSession(apiClient: client)

        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedPath, "/sessions")
        XCTAssertEqual(session.id, fixedSessionId)
        XCTAssertEqual(sut.current?.id, fixedSessionId,
                       "beginSession must store the server-minted session on self.current")
    }

    // MARK: - endSession happy path

    func testEndSessionDeletesAndClearsCurrent() async throws {
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                return (response(201, for: request), sessionJSON)
            }
            // DELETE /sessions/{id}
            return (response(200, for: request), sessionJSON)
        }

        _ = try await sut.beginSession(apiClient: client)
        XCTAssertNotNil(sut.current, "precondition")

        await sut.endSession(apiClient: client)
        XCTAssertNil(sut.current, "endSession must clear current on 2xx")
    }

    // MARK: - 404 / 410 are idempotent success

    func testEndSession404TreatedAsSuccess() async throws {
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                return (response(201, for: request), sessionJSON)
            }
            return (response(404, for: request), Data())
        }
        _ = try await sut.beginSession(apiClient: client)

        await sut.endSession(apiClient: client)

        XCTAssertNil(sut.current,
                     "404 on DELETE means the session is already gone server-side — clear locally")
    }

    func testEndSession410TreatedAsSuccess() async throws {
        let client = makeClient { [self] request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sessions" {
                return (response(201, for: request), sessionJSON)
            }
            return (response(410, for: request), Data())
        }
        _ = try await sut.beginSession(apiClient: client)

        await sut.endSession(apiClient: client)

        XCTAssertNil(sut.current,
                     "410 Gone on DELETE is idempotent success — client treats as already closed")
    }

    // MARK: - Network failure on end is best-effort

    func testEndSessionNetworkFailureStillClearsCurrent() async throws {
        let client = makeClient { [self] request in
            if request.httpMethod == "POST" {
                return (response(201, for: request), sessionJSON)
            }
            throw URLError(.notConnectedToInternet)
        }
        _ = try await sut.beginSession(apiClient: client)

        await sut.endSession(apiClient: client)

        XCTAssertNil(sut.current,
                     "Network failure on close must not block UX — clear locally so the user can start fresh; server idle-cleanup covers the row")
    }

    // MARK: - Idle timer

    func testIdleTimerAutoClosesSessionAfterTimeout() async throws {
        sut = SessionManager(idleTimeout: 0.15) // short for test
        let client = makeClient { [self] request in
            if request.httpMethod == "POST" {
                return (response(201, for: request), sessionJSON)
            }
            return (response(200, for: request), sessionJSON)
        }
        _ = try await sut.beginSession(apiClient: client)

        sut.noteActivity(apiClient: client) // arms the timer
        // Wait longer than idleTimeout so the Task fires.
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNil(sut.current,
                     "30-min idle timer — simulated at 0.15s here — must auto-end the session")
    }

    func testNoteActivityResetsIdleTimer() async throws {
        sut = SessionManager(idleTimeout: 0.25)
        let client = makeClient { [self] request in
            if request.httpMethod == "POST" {
                return (response(201, for: request), sessionJSON)
            }
            return (response(200, for: request), sessionJSON)
        }
        _ = try await sut.beginSession(apiClient: client)

        sut.noteActivity(apiClient: client)
        try await Task.sleep(nanoseconds: 120_000_000) // 0.12s — not yet idle
        sut.noteActivity(apiClient: client) // reset
        try await Task.sleep(nanoseconds: 120_000_000) // 0.24s total, but reset at 0.12 — still within window

        XCTAssertNotNil(sut.current,
                        "noteActivity must reset the idle timer so active users aren't auto-logged-out")
    }

    // MARK: - invalidateCurrentSession

    func testInvalidateCurrentSessionClearsWithoutNetworkCall() async throws {
        let client = makeClient { [self] request in
            (response(201, for: request), sessionJSON)
        }
        _ = try await sut.beginSession(apiClient: client)

        // Simulate the server returning 400 invalid_session on a later ingest:
        // callers tell the SessionManager to drop the current session so the
        // next ingest auto-begins a fresh one.
        sut.invalidateCurrentSession()

        XCTAssertNil(sut.current,
                     "invalidateCurrentSession must clear current with no network call")
    }

    // MARK: - activeSessionId auto-begins

    func testActiveSessionIdAutoBeginsWhenCurrentIsNil() async throws {
        var postCount = 0
        let client = makeClient { [self] request in
            if request.httpMethod == "POST" {
                postCount += 1
                return (response(201, for: request), sessionJSON)
            }
            return (response(200, for: request), sessionJSON)
        }

        let id = try await sut.activeSessionId(apiClient: client)

        XCTAssertEqual(id, fixedSessionId)
        XCTAssertEqual(postCount, 1, "Nil current must trigger POST /sessions")
        XCTAssertNotNil(sut.current, "current must be populated after auto-begin")
    }

    /// Swift2_019b — F-2 / SEC-24-2. Two concurrent callers must coalesce
    /// into a single `POST /sessions`. Before the fix, `activeSessionId`
    /// suspends on `await beginSession`; both callers pass the `current
    /// == nil` gate and both fire a POST, creating orphan sessions that
    /// count against the server's 20-open cap.
    func testActiveSessionIdSerializesConcurrentCallers() async throws {
        var postCount = 0
        let client = makeClient { [self] request in
            if request.httpMethod == "POST", request.url?.path == "/sessions" {
                postCount += 1
                return (response(201, for: request), sessionJSON)
            }
            return (response(500, for: request), Data())
        }

        async let a: UUID = sut.activeSessionId(apiClient: client)
        async let b: UUID = sut.activeSessionId(apiClient: client)
        async let c: UUID = sut.activeSessionId(apiClient: client)
        let (ida, idb, idc) = try await (a, b, c)

        XCTAssertEqual(postCount, 1,
                       "Concurrent activeSessionId callers must coalesce into ONE POST /sessions")
        XCTAssertEqual(ida, fixedSessionId)
        XCTAssertEqual(idb, fixedSessionId)
        XCTAssertEqual(idc, fixedSessionId)
    }

    func testActiveSessionIdReturnsExistingWithoutBeginning() async throws {
        var postCount = 0
        let client = makeClient { [self] request in
            if request.httpMethod == "POST" {
                postCount += 1
                return (response(201, for: request), sessionJSON)
            }
            return (response(200, for: request), sessionJSON)
        }
        _ = try await sut.beginSession(apiClient: client)
        XCTAssertEqual(postCount, 1, "precondition: one begin")

        let id = try await sut.activeSessionId(apiClient: client)

        XCTAssertEqual(id, fixedSessionId)
        XCTAssertEqual(postCount, 1,
                       "Existing current must not trigger another POST /sessions")
    }
}
