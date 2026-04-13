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
    var testKeychain: InMemoryKeychainHelper!

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
        testKeychain = InMemoryKeychainHelper()
        // Isolate tests from the host bundle's Info.plist so BuildConfig
        // defaults don't bleed into tests that assert the hardcoded fallback.
        BuildConfig.lookup = { _ in nil }
        sut = SettingsViewModel(defaults: testDefaults, keychain: testKeychain)
    }

    override func tearDown() async throws {
        SettingsMockURLProtocol.requestHandler = nil
        testDefaults.removePersistentDomain(forName: suiteName)
        BuildConfig.lookup = { key in Bundle.main.object(forInfoDictionaryKey: key) }
        sut = nil
        testDefaults = nil
        suiteName = nil
        testKeychain = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockAPIClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        SettingsMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsMockURLProtocol.self]
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

    private var healthSuccessJSON: Data {
        // Legacy shape (no auth_ok) — decodes as `connectedNoKey`.
        Data("""
        {"version":"1","ok":true,"db_ok":true,"embed_model":"nomic-embed-text","expected_dims":768}
        """.utf8)
    }

    private var healthErrorJSON: Data {
        Data("""
        {"version":"1","error":{"code":"server_error","message":"Internal server error"}}
        """.utf8)
    }

    private var healthValidKeyUserJSON: Data {
        Data("""
        {"version":"1","ok":true,"db_ok":true,"embed_model":"BAAI/bge-small-en-v1.5","expected_dims":384,"auth_ok":true,"role":"user"}
        """.utf8)
    }

    private var healthInvalidKeyJSON: Data {
        Data("""
        {"version":"1","ok":true,"db_ok":true,"embed_model":"BAAI/bge-small-en-v1.5","expected_dims":384,"auth_ok":false}
        """.utf8)
    }

    private var healthNoKeyJSON: Data {
        Data("""
        {"version":"1","ok":true,"db_ok":true,"embed_model":"BAAI/bge-small-en-v1.5","expected_dims":384}
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

    // MARK: - Test 1b: BuildConfig defaults populate fields when UserDefaults/Keychain are empty

    func testBuildConfigDefaultsPopulateServerURLWhenUserDefaultsEmpty() {
        BuildConfig.lookup = { key in
            key == "DefaultServerURL" ? "http://dev.local:9000" : nil
        }
        let vm = SettingsViewModel(defaults: testDefaults, keychain: testKeychain)
        XCTAssertEqual(vm.serverURL, "http://dev.local:9000",
                       "serverURL should pick up BuildConfig value when UserDefaults has no override")
    }

    func testBuildConfigDefaultsPopulateAPIKeyWhenKeychainEmpty() {
        BuildConfig.lookup = { key in
            key == "DefaultAPIKey" ? "bb_devkey_123" : nil
        }
        let vm = SettingsViewModel(defaults: testDefaults, keychain: testKeychain)
        XCTAssertEqual(vm.apiKey, "bb_devkey_123",
                       "apiKey should pick up BuildConfig value when Keychain has no entry")
    }

    func testUserDefaultsOverridesBuildConfigServerURL() {
        testDefaults.set("http://user.override:7000", forKey: "serverURL")
        BuildConfig.lookup = { key in
            key == "DefaultServerURL" ? "http://dev.local:9000" : nil
        }
        let vm = SettingsViewModel(defaults: testDefaults, keychain: testKeychain)
        XCTAssertEqual(vm.serverURL, "http://user.override:7000",
                       "UserDefaults value should win over BuildConfig default")
    }

    func testKeychainOverridesBuildConfigAPIKey() throws {
        try testKeychain.writeString("user-entered-key", forKey: KeychainHelper.apiKeyAccount)
        BuildConfig.lookup = { key in
            key == "DefaultAPIKey" ? "bb_devkey_123" : nil
        }
        let vm = SettingsViewModel(defaults: testDefaults, keychain: testKeychain)
        XCTAssertEqual(vm.apiKey, "user-entered-key",
                       "Keychain value should win over BuildConfig default")
    }

    // MARK: - Test 2: testConnection sets .connected(role:) when key is valid

    func testTestConnectionSetsConnectedWhenKeyIsValid() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthValidKeyUserJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .connected(role: .user),
                       "connectionStatus should be .connected(role: .user) when auth_ok=true")
    }

    // MARK: - Test 2b: testConnection sets .connectedKeyInvalid when server rejects key

    func testTestConnectionSetsKeyInvalidWhenAuthFails() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthInvalidKeyJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .connectedKeyInvalid,
                       "connectionStatus should be .connectedKeyInvalid when auth_ok=false")
    }

    // MARK: - Test 2c: testConnection sets .connectedNoKey when auth_ok is absent

    func testTestConnectionSetsNoKeyWhenAuthOkAbsent() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthNoKeyJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .connectedNoKey,
                       "connectionStatus should be .connectedNoKey when auth_ok is missing")
    }

    // MARK: - Test 3: testConnection sets .unreachable on non-2xx

    func testTestConnectionSetsUnreachableOnError() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), healthErrorJSON)
        }

        await sut.testConnection(apiClient: client)

        guard case .unreachable = sut.connectionStatus else {
            XCTFail("connectionStatus should be .unreachable after a 500 health response; got \(sut.connectionStatus)")
            return
        }
    }

    // MARK: - Test 3b: testConnection sets connectionErrorMessage on failure

    func testTestConnectionSetsErrorMessageOnFailure() async {
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), healthErrorJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertNotNil(sut.connectionErrorMessage,
                        "connectionErrorMessage should be populated after a failing health check")
    }

    // MARK: - Test 3c: testConnection clears connectionErrorMessage on success

    func testTestConnectionClearsErrorMessageOnSuccess() async {
        let failClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), healthErrorJSON)
        }
        await sut.testConnection(apiClient: failClient)
        XCTAssertNotNil(sut.connectionErrorMessage,
                        "precondition: failure populates connectionErrorMessage")

        let successClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthSuccessJSON)
        }
        await sut.testConnection(apiClient: successClient)

        XCTAssertNil(sut.connectionErrorMessage,
                     "connectionErrorMessage should clear on a successful health check")
    }

    // MARK: - Test 4: connectionStatus transitions from unreachable to connected

    func testTestConnectionTransitionsFromUnreachableToConnected() async {
        // First call: put sut into .unreachable state
        let failClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 500, for: request), healthErrorJSON)
        }
        await sut.testConnection(apiClient: failClient)
        guard case .unreachable = sut.connectionStatus else {
            XCTFail("precondition: first call should leave status .unreachable; got \(sut.connectionStatus)")
            return
        }

        // Second call: a successful authenticated call should end in .connected(role: .user)
        let successClient = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthValidKeyUserJSON)
        }
        await sut.testConnection(apiClient: successClient)
        XCTAssertEqual(sut.connectionStatus, .connected(role: .user),
                       "connectionStatus should be .connected(role: .user) after the second (successful) call")
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

    // MARK: - Test 7: debouncedSave coalesces rapid calls

    @MainActor
    func testDebouncedSaveCoalescesRapidWrites() async throws {
        // Simulate rapid typing — each keystroke calls debouncedSave
        sut.serverURL = "http://a"
        sut.debouncedSave(to: testDefaults)
        sut.serverURL = "http://ab"
        sut.debouncedSave(to: testDefaults)
        sut.serverURL = "http://abc"
        sut.debouncedSave(to: testDefaults)

        // Before debounce fires, defaults should still hold the old value
        XCTAssertNil(testDefaults.string(forKey: "serverURL"),
                     "Defaults should not be written immediately during rapid calls")

        // Wait for debounce to settle (500ms + margin)
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(testDefaults.string(forKey: "serverURL"), "http://abc",
                       "After debounce settles, only the final value should be persisted")
    }

    // MARK: - Test 8: loads previously persisted values

    func testLoadsPreviouslyPersistedValues() async {
        testDefaults.set("http://customhost.local:9000", forKey: "serverURL")
        testDefaults.set(0.8, forKey: "similarityThreshold")

        let loaded = SettingsViewModel(defaults: testDefaults)

        XCTAssertEqual(loaded.serverURL, "http://customhost.local:9000",
                       "SettingsViewModel should load persisted serverURL from defaults")
        XCTAssertEqual(loaded.similarityThreshold, 0.8,
                       "SettingsViewModel should load persisted similarityThreshold from defaults")
    }

    // MARK: - Test 9: user-set threshold of 0 is preserved across reloads (Issue #7)

    func testThresholdZeroIsPreservedAcrossReloads() {
        sut.similarityThreshold = 0.0
        sut.save(to: testDefaults)

        let reloaded = SettingsViewModel(defaults: testDefaults)

        XCTAssertEqual(reloaded.similarityThreshold, 0.0,
                       "A user-set threshold of 0 must not be silently reset to 0.5 on reload")
    }

    // MARK: - Test 10: unset threshold still defaults to 0.5 (Issue #7)

    func testUnsetThresholdDefaultsToHalf() {
        // testDefaults has no similarityThreshold key set
        let loaded = SettingsViewModel(defaults: testDefaults)

        XCTAssertEqual(loaded.similarityThreshold, 0.5,
                       "An unset threshold should default to 0.5")
    }

    // MARK: - HealthResponse decode tests (Issue #8)

    func testHealthResponseDecodesValidKeyShape() throws {
        let decoded = try JSONDecoder.binBrain.decode(HealthResponse.self, from: healthValidKeyUserJSON)
        XCTAssertEqual(decoded.authOk, true)
        XCTAssertEqual(decoded.role, .user)
    }

    func testHealthResponseDecodesInvalidKeyShape() throws {
        let decoded = try JSONDecoder.binBrain.decode(HealthResponse.self, from: healthInvalidKeyJSON)
        XCTAssertEqual(decoded.authOk, false)
        XCTAssertNil(decoded.role,
                     "role must be nil when the server rejected the key")
    }

    func testHealthResponseDecodesNoKeyShape() throws {
        let decoded = try JSONDecoder.binBrain.decode(HealthResponse.self, from: healthNoKeyJSON)
        XCTAssertNil(decoded.authOk,
                     "authOk must be nil when no X-API-Key header was sent")
        XCTAssertNil(decoded.role)
    }

    // MARK: - Host binding (#13)

    func testTestConnectionReportsKeyNotBoundWhenHostMismatched() async {
        // Seed a key bound to a different host.
        try? testKeychain.writeAPIKeyBinding(
            key: "k", boundHost: "http://10.1.1.205:8000"
        )
        sut.serverURL = "http://10.1.1.207:8000"

        // Default health() does not send the key, so the server reports auth_ok absent.
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthNoKeyJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertEqual(sut.connectionStatus,
                       .connectedKeyNotBoundToHost(canRebind: true),
                       "When auth_ok is absent and a Keychain key exists bound to another host, status must be .connectedKeyNotBoundToHost(canRebind: true)")
    }

    func testTestConnectionStaysNoKeyWhenKeychainEmpty() async {
        // No key in keychain, server reports auth_ok absent.
        sut.serverURL = "http://10.1.1.207:8000"
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthNoKeyJSON)
        }

        await sut.testConnection(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .connectedNoKey,
                       "Without a Keychain key, auth_ok absent maps to .connectedNoKey, not .connectedKeyNotBoundToHost")
    }

    func testRebindKeyUpdatesBoundHostOnAuthOkTrue() async {
        try? testKeychain.writeAPIKeyBinding(
            key: "k", boundHost: "http://old:8000"
        )
        sut.serverURL = "http://new:8000"

        // Probe with key returns auth_ok: true.
        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthValidKeyUserJSON)
        }

        await sut.rebindKey(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .connected(role: .user))
        XCTAssertEqual(testKeychain.readString(forKey: KeychainHelper.boundHostAccount),
                       "http://new:8000",
                       "Successful re-bind must persist the new origin to the Keychain")
    }

    func testRebindKeyReportsInvalidKeyOnAuthOkFalse() async {
        try? testKeychain.writeAPIKeyBinding(
            key: "k", boundHost: "http://old:8000"
        )
        sut.serverURL = "http://new:8000"

        let client = makeMockAPIClient { [self] request in
            return (mockResponse(statusCode: 200, for: request), healthInvalidKeyJSON)
        }

        await sut.rebindKey(apiClient: client)

        XCTAssertEqual(sut.connectionStatus, .connectedKeyInvalid,
                       "auth_ok=false on re-bind probe means the key isn't valid for this host either")
        XCTAssertEqual(testKeychain.readString(forKey: KeychainHelper.boundHostAccount),
                       "http://old:8000",
                       "Failed re-bind must NOT touch the existing bound host")
    }

    // MARK: - API key commit persistence (#11)

    func testCommitAPIKeyPersistsKeyAndBoundHost() {
        sut.serverURL = "http://host:8000"
        sut.apiKey = "fresh-key"

        sut.commitAPIKey()

        XCTAssertEqual(testKeychain.readString(forKey: KeychainHelper.apiKeyAccount), "fresh-key")
        XCTAssertEqual(testKeychain.readString(forKey: KeychainHelper.boundHostAccount), "http://host:8000",
                       "commitAPIKey() must record the normalized origin alongside the key")
    }

    func testCommitAPIKeyClearsBindingWhenEmpty() {
        try? testKeychain.writeAPIKeyBinding(
            key: "old", boundHost: "http://host:8000"
        )
        sut.apiKey = ""

        sut.commitAPIKey()

        XCTAssertNil(testKeychain.readString(forKey: KeychainHelper.apiKeyAccount),
                     "Clearing apiKey + commit must remove the key from Keychain immediately")
        XCTAssertNil(testKeychain.readString(forKey: KeychainHelper.boundHostAccount))
    }

    func testSaveDoesNotWriteAPIKeyToKeychain() {
        // Simulates the debounce path: user is mid-edit, save() fires on timer.
        // With #11, save() must no longer touch Keychain for the apiKey field —
        // persistence is reserved for explicit commit (blur / Return / Save).
        sut.serverURL = "http://host:8000"
        sut.apiKey = "partial-key-being-typed"

        sut.save(to: testDefaults)

        XCTAssertNil(testKeychain.readString(forKey: KeychainHelper.apiKeyAccount),
                     "save() (debounce path) must NOT persist a half-typed apiKey to Keychain")
        XCTAssertNil(testKeychain.readString(forKey: KeychainHelper.boundHostAccount),
                     "save() must not record a bound host for an uncommitted key")
    }

    @MainActor
    func testDebouncedSaveDoesNotPersistAPIKey() async throws {
        // Regression guard for F-12 / #11: the debounce path is for
        // non-credential settings only. Typing in the apiKey field — even
        // after the debounce settles — must leave Keychain untouched.
        sut.serverURL = "http://host:8000"
        sut.apiKey = "abc"
        sut.debouncedSave(to: testDefaults)
        sut.apiKey = "abcd"
        sut.debouncedSave(to: testDefaults)

        try await Task.sleep(for: .milliseconds(700))

        XCTAssertNil(testKeychain.readString(forKey: KeychainHelper.apiKeyAccount),
                     "Debounced typing in apiKey field must not reach Keychain — commitAPIKey() is the only persistence path")
    }
}
