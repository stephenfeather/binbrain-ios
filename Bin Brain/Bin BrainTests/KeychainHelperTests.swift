// KeychainHelperTests.swift
// Bin BrainTests
//
// XCTest coverage for KeychainHelper round-trip behavior and the
// one-time UserDefaults→Keychain migration.

import XCTest
@testable import Bin_Brain

// MARK: - InMemoryKeychainHelper

/// Dictionary-backed `KeychainReading` for tests.
///
/// Keeps state in-process so tests never touch the real Keychain and
/// never leak state across runs. Thread-safe via a serial queue.
final class InMemoryKeychainHelper: KeychainReading, @unchecked Sendable {
    private let queue = DispatchQueue(label: "InMemoryKeychainHelper")
    private var storage: [String: String]
    private var writeFailures: Set<String>

    init(seeded: [String: String] = [:], failWritesForKeys: Set<String> = []) {
        self.storage = seeded
        self.writeFailures = failWritesForKeys
    }

    func readString(forKey key: String) -> String? {
        queue.sync { storage[key] }
    }

    func writeString(_ value: String, forKey key: String) throws {
        try queue.sync {
            if writeFailures.contains(key) {
                throw KeychainError.unexpectedStatus(-9999)
            }
            storage[key] = value
        }
    }

    func removeValue(forKey key: String) throws {
        _ = queue.sync { storage.removeValue(forKey: key) }
    }

    /// Test-only accessor for asserting total entry count.
    var entryCount: Int { queue.sync { storage.count } }
}

// MARK: - KeychainHelperTests

final class KeychainHelperTests: XCTestCase {

    var sut: KeychainHelper!
    var service: String!

    override func setUp() async throws {
        try await super.setUp()
        // Unique service per test so real-Keychain state never leaks.
        service = "com.binbrain.tests.\(UUID().uuidString)"
        sut = KeychainHelper(service: service)
    }

    override func tearDown() async throws {
        try? sut.removeValue(forKey: "apiKey")
        try? sut.removeValue(forKey: "other")
        sut = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - Round-trip

    func testWriteThenReadReturnsValue() throws {
        try sut.writeString("hunter2", forKey: "apiKey")

        XCTAssertEqual(sut.readString(forKey: "apiKey"), "hunter2")
    }

    func testReadReturnsNilWhenAbsent() {
        XCTAssertNil(sut.readString(forKey: "apiKey"))
    }

    func testWriteOverwritesExistingValue() throws {
        try sut.writeString("first", forKey: "apiKey")
        try sut.writeString("second", forKey: "apiKey")

        XCTAssertEqual(sut.readString(forKey: "apiKey"), "second")
    }

    func testRemoveErasesValue() throws {
        try sut.writeString("will-go-away", forKey: "apiKey")
        try sut.removeValue(forKey: "apiKey")

        XCTAssertNil(sut.readString(forKey: "apiKey"))
    }

    func testRemoveOnMissingKeyDoesNotThrow() {
        XCTAssertNoThrow(try sut.removeValue(forKey: "apiKey"))
    }

    func testDistinctKeysAreIndependent() throws {
        try sut.writeString("a", forKey: "apiKey")
        try sut.writeString("b", forKey: "other")

        XCTAssertEqual(sut.readString(forKey: "apiKey"), "a")
        XCTAssertEqual(sut.readString(forKey: "other"), "b")
    }
}

// MARK: - Migration tests

final class KeychainMigrationTests: XCTestCase {

    var keychain: InMemoryKeychainHelper!
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        keychain = InMemoryKeychainHelper()
        suiteName = "KeychainMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: -

    func testMigrationIsNoOpWhenUserDefaultsEmpty() {
        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded(
            keychain: keychain, defaults: defaults
        )

        XCTAssertNil(keychain.readString(forKey: "apiKey"),
                     "Keychain must remain empty when UserDefaults had no key")
        XCTAssertEqual(keychain.entryCount, 0)
    }

    func testMigrationMovesValueFromUserDefaultsWhenPresent() {
        defaults.set("legacy-key", forKey: "apiKey")

        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded(
            keychain: keychain, defaults: defaults
        )

        XCTAssertEqual(keychain.readString(forKey: "apiKey"), "legacy-key",
                       "Keychain must receive the migrated value")
        XCTAssertNil(defaults.string(forKey: "apiKey"),
                     "UserDefaults entry must be cleared after a successful migration")
    }

    func testMigrationDoesNotOverwriteExistingKeychainValue() {
        try? keychain.writeString("already-here", forKey: "apiKey")
        defaults.set("legacy-key", forKey: "apiKey")

        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded(
            keychain: keychain, defaults: defaults
        )

        XCTAssertEqual(keychain.readString(forKey: "apiKey"), "already-here",
                       "Existing Keychain value must not be overwritten")
        XCTAssertNil(defaults.string(forKey: "apiKey"),
                     "UserDefaults entry must still be cleared to finish the migration")
    }

    func testMigrationIsIdempotent() {
        defaults.set("legacy-key", forKey: "apiKey")

        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded(
            keychain: keychain, defaults: defaults
        )
        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded(
            keychain: keychain, defaults: defaults
        )

        XCTAssertEqual(keychain.readString(forKey: "apiKey"), "legacy-key")
        XCTAssertNil(defaults.string(forKey: "apiKey"))
    }

    func testMigrationIgnoresEmptyStringInUserDefaults() {
        defaults.set("", forKey: "apiKey")

        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded(
            keychain: keychain, defaults: defaults
        )

        XCTAssertNil(keychain.readString(forKey: "apiKey"),
                     "Empty-string legacy value must not migrate")
    }
}

// MARK: - Atomic API-key binding tests

final class KeychainAtomicBindingTests: XCTestCase {

    func testWriteAPIKeyBindingPersistsBoth() throws {
        let keychain = InMemoryKeychainHelper()

        try keychain.writeAPIKeyBinding(key: "k", boundHost: "http://host:8000")

        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.apiKeyAccount), "k")
        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.boundHostAccount), "http://host:8000")
    }

    func testBoundHostWriteFailureRollsBackKey() {
        let keychain = InMemoryKeychainHelper(failWritesForKeys: [KeychainHelper.boundHostAccount])

        XCTAssertThrowsError(
            try keychain.writeAPIKeyBinding(key: "k", boundHost: "http://host:8000")
        )

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.apiKeyAccount),
                     "apiKey must be rolled back when the bound-host write fails — never persist an unbound key")
        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }

    func testClearAPIKeyBindingRemovesBoth() throws {
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "k",
            KeychainHelper.boundHostAccount: "http://host:8000"
        ])

        try keychain.clearAPIKeyBinding()

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.apiKeyAccount))
        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }
}

// MARK: - Bound-host migration tests

final class KeychainBoundHostMigrationTests: XCTestCase {

    var keychain: InMemoryKeychainHelper!
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        keychain = InMemoryKeychainHelper()
        suiteName = "KeychainBoundHostMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testMigrationIsNoOpWhenNoAPIKey() {
        defaults.set("http://10.1.1.206:8000", forKey: "serverURL")

        KeychainHelper.migrateAPIKeyBoundHostIfNeeded(keychain: keychain, defaults: defaults)

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }

    func testMigrationBacksFillsBoundHostFromServerURL() throws {
        try keychain.writeString("k", forKey: KeychainHelper.apiKeyAccount)
        defaults.set("http://10.1.1.206:8000/", forKey: "serverURL")

        KeychainHelper.migrateAPIKeyBoundHostIfNeeded(keychain: keychain, defaults: defaults)

        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.boundHostAccount),
                       "http://10.1.1.206:8000",
                       "Bound host must be the normalized origin of serverURL")
    }

    func testMigrationDoesNotOverwriteExistingBoundHost() throws {
        try keychain.writeString("k", forKey: KeychainHelper.apiKeyAccount)
        try keychain.writeString("http://existing:8000", forKey: KeychainHelper.boundHostAccount)
        defaults.set("http://10.1.1.206:8000", forKey: "serverURL")

        KeychainHelper.migrateAPIKeyBoundHostIfNeeded(keychain: keychain, defaults: defaults)

        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.boundHostAccount),
                       "http://existing:8000")
    }

    func testMigrationLeavesBoundHostUnsetWhenServerURLMissing() throws {
        try keychain.writeString("k", forKey: KeychainHelper.apiKeyAccount)

        KeychainHelper.migrateAPIKeyBoundHostIfNeeded(keychain: keychain, defaults: defaults)

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }
}
