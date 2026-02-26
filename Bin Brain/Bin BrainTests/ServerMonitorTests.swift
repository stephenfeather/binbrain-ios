// ServerMonitorTests.swift
// Bin BrainTests
//
// XCTest coverage for ServerMonitor.swift using ServerMonitorMockURLProtocol
// to intercept URLSession calls without a live server.

import XCTest
@testable import Bin_Brain

// MARK: - ServerMonitorMockURLProtocol

/// A URLProtocol subclass that intercepts all requests for ServerMonitor tests.
///
/// Uses a distinct name to avoid symbol collision with `MockURLProtocol`
/// defined in APIClientTests.swift.
final class ServerMonitorMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ServerMonitorMockURLProtocol.requestHandler else {
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

/// Builds a minimal `HTTPURLResponse` for use in ServerMonitor mock handlers.
private func makeServerMonitorResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://mock")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

// MARK: - ServerMonitorTests

final class ServerMonitorTests: XCTestCase {

    var sut: ServerMonitor!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = ServerMonitor()
    }

    override func tearDown() async throws {
        ServerMonitorMockURLProtocol.requestHandler = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Factory

    /// Creates an `APIClient` backed by `ServerMonitorMockURLProtocol`.
    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        ServerMonitorMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerMonitorMockURLProtocol.self]
        return APIClient(session: URLSession(configuration: config))
    }

    // MARK: - Test 1: Initial state

    func testInitialIsReachableIsFalse() {
        XCTAssertFalse(sut.isReachable, "A freshly created ServerMonitor should be unreachable")
    }

    // MARK: - Test 2: 200 response sets isReachable true

    func testCheckSetsReachableOnSuccess() async {
        let client = makeMockAPIClient { _ in
            let json = Data("""
            {"version":"1","ok":true,"db_ok":true,"embed_model":"BAAI/bge-small-en-v1.5","expected_dims":384}
            """.utf8)
            return (makeServerMonitorResponse(statusCode: 200), json)
        }

        await sut.check(using: client)

        XCTAssertTrue(sut.isReachable, "isReachable should be true after a successful health check")
    }

    // MARK: - Test 3: 503 HTTP error sets isReachable false

    func testCheckSetsUnreachableOnHTTPError() async {
        let client = makeMockAPIClient { _ in
            let json = Data("""
            {"version":"1","error":{"code":"unavailable","message":"Database down"}}
            """.utf8)
            return (makeServerMonitorResponse(statusCode: 503), json)
        }

        await sut.check(using: client)

        XCTAssertFalse(sut.isReachable, "isReachable should be false after a 503 response")
    }

    // MARK: - Test 4: Network error sets isReachable false

    func testCheckSetsUnreachableOnNetworkError() async {
        let client = makeMockAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sut.check(using: client)

        XCTAssertFalse(sut.isReachable, "isReachable should be false when the network is unreachable")
    }

    // MARK: - Test 5: check() never throws even when server is down

    func testCheckDoesNotThrow() async {
        let client = makeMockAPIClient { _ in
            throw URLError(.timedOut)
        }

        // If check() propagated an error, awaiting it here without try would not compile,
        // but the call must also not crash at runtime. Reaching the assertion confirms it.
        await sut.check(using: client)

        XCTAssertFalse(sut.isReachable, "isReachable should be false; check() must never throw")
    }

    // MARK: - Test 6: Repeated checks reflect the latest server state

    func testCheckUpdatesReachabilityOnSubsequentCalls() async {
        // First call succeeds — isReachable becomes true.
        let successClient = makeMockAPIClient { _ in
            let json = Data("""
            {"version":"1","ok":true,"db_ok":true,"embed_model":"BAAI/bge-small-en-v1.5","expected_dims":384}
            """.utf8)
            return (makeServerMonitorResponse(statusCode: 200), json)
        }
        await sut.check(using: successClient)
        XCTAssertTrue(sut.isReachable)

        // Second call fails — isReachable must revert to false.
        let failClient = makeMockAPIClient { _ in
            throw URLError(.timedOut)
        }
        await sut.check(using: failClient)
        XCTAssertFalse(sut.isReachable, "isReachable should revert to false when the server becomes unreachable")
    }
}
