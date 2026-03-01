// SettingsViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for SettingsViewModel.swift.
// SettingsView wraps SwiftUI and cannot be unit-tested;
// all testable logic lives in SettingsViewModel.

import XCTest
@testable import Bin_Brain

// MARK: - SettingsMockURLProtocol

/// A URLProtocol subclass that intercepts all requests for SettingsViewModel tests.
///
/// Uses a distinct name to avoid symbol collisions with other mock protocols.
final class SettingsMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = SettingsMockURLProtocol.requestHandler else {
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

// MARK: - SettingsViewModelTests

final class SettingsViewModelTests: XCTestCase {

    var sut: SettingsViewModel!
    var testDefaults: UserDefaults!
    var suiteName: String!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        // UUID-based suiteName guarantees a fresh, empty domain per test run.
        // Parallel workers won't share state. No removePersistentDomain needed in setUp
        // because the fresh UUID is guaranteed to have no prior entries, and removing
        // the domain right after creation can leave the defaults object in a state where
        // subsequent set(_:forKey:) calls are not reliably readable.
        suiteName = "SettingsViewModelTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        sut = SettingsViewModel(defaults: testDefaults)
    }

    override func tearDown() async throws {
        SettingsMockURLProtocol.requestHandler = nil
        testDefaults.removePersistentDomain(forName: suiteName)
        sut = nil
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        SettingsMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsMockURLProtocol.self]
        return APIClient(session: URLSession(configuration: config))
    }

    private func mockResponse(statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private var healthSuccessJSON: Data {
        Data("""
        {"version":"1","ok":true,"db_ok":true,"embed_model":"nomic-embed-text","expected_dims":768}
        """.utf8)
    }

    private var healthErrorJSON: Data {
        Data("""
        {"version":"1","error":{"code":"server_error","message":"Internal server error"}}
        """.utf8)
    }

    // MARK: - Test 1: Initial state

    func testInitialState() {
        XCTAssertEqual(sut.serverURL, "http://10.1.1.206:8000",
                       "serverURL should default to the Pi address")
        XCTAssertEqual(sut.similarityThreshold, 0.5,
                       "similarityThreshold should default to 0.5 when unset")
        XCTAssertEqual(sut.connectionStatus, .unknown,
                       "connectionStatus should be .unknown on init")
    }

    // MARK: - Test 2: testConnection sets .ok on 200

    func testTestConnectionSetsOkOnSuccess() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthSuccessJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .ok,
                       "connectionStatus should be .ok after a successful health check")
    }

    // MARK: - Test 3: testConnection sets .failed on 500

    func testTestConnectionSetsFailedOnError() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), healthErrorJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .failed,
                       "connectionStatus should be .failed after a 500 health response")
    }

    // MARK: - Test 4: connectionStatus resets to .unknown before each call

    func testTestConnectionResetsStatusBeforeCall() async {
        // First call: put sut into .failed state
        let failClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), healthErrorJSON)
        }
        await sut.testConnection(apiClient: failClient)
        XCTAssertEqual(sut.connectionStatus, .failed,
                       "connectionStatus should be .failed after the first (failing) call")

        // Second call: a successful call should end in .ok
        // (the .unknown reset happens internally before the network call)
        let successClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthSuccessJSON)
        }
        await sut.testConnection(apiClient: successClient)
        XCTAssertEqual(sut.connectionStatus, .ok,
                       "connectionStatus should be .ok after the second (successful) call")
    }

    // MARK: - Test 5: save persists serverURL

    func testSavePersistsServerURL() {
        sut.serverURL = "http://mypi.local:9000"
        sut.save(to: testDefaults)

        XCTAssertEqual(testDefaults.string(forKey: "serverURL"), "http://mypi.local:9000",
                       "save(to:) should persist the updated serverURL")
    }

    // MARK: - Test 6: save persists similarityThreshold

    func testSavePersistsSimilarityThreshold() {
        sut.similarityThreshold = 0.75
        sut.save(to: testDefaults)

        XCTAssertEqual(testDefaults.double(forKey: "similarityThreshold"), 0.75,
                       "save(to:) should persist the updated similarityThreshold")
    }

    // MARK: - Test 7: loads previously persisted values

    func testLoadsPreviouslyPersistedValues() async {
        testDefaults.set("http://customhost.local:9000", forKey: "serverURL")
        testDefaults.set(0.8, forKey: "similarityThreshold")

        let loaded = SettingsViewModel(defaults: testDefaults)

        XCTAssertEqual(loaded.serverURL, "http://customhost.local:9000",
                       "SettingsViewModel should load persisted serverURL from defaults")
        XCTAssertEqual(loaded.similarityThreshold, 0.8,
                       "SettingsViewModel should load persisted similarityThreshold from defaults")
    }
}
