// KeychainHelperDebugSeedTests.swift
// Bin BrainTests
//
// DEBUG-only tests for the API-key fallback seed.
//
// The entire file is gated on `#if DEBUG`. The production code that
// implements `seedDebugAPIKeyFromBuildConfigIfNeeded` is also gated on
// `#if DEBUG`, so the symbol is unreachable — and therefore these tests
// cannot compile — in non-DEBUG builds. That is the intended guarantee.

#if DEBUG
import XCTest
@testable import Bin_Brain

@MainActor
final class KeychainHelperDebugSeedTests: XCTestCase {

    override func tearDown() async throws {
        BuildConfig.lookup = { key in
            Bundle.main.object(forInfoDictionaryKey: key)
        }
        try await super.tearDown()
    }

    // MARK: - Seeds when Keychain is empty

    func testSeedsKeyAndBoundHostWhenKeychainEmptyAndBuildConfigComplete() throws {
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultAPIKey": return "bb_debug_seed_key"
            case "DefaultServerURL": return "http://10.1.1.205:8000"
            default: return nil
            }
        }
        let keychain = InMemoryKeychainHelper()

        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded(keychain: keychain)

        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.apiKeyAccount),
                       "bb_debug_seed_key")
        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.boundHostAccount),
                       "http://10.1.1.205:8000")
    }

    // MARK: - No-op when server URL absent

    func testDoesNotSeedWhenDefaultServerURLAbsent() {
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultAPIKey": return "bb_debug_seed_key"
            case "DefaultServerURL": return nil
            default: return nil
            }
        }
        let keychain = InMemoryKeychainHelper()

        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded(keychain: keychain)

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.apiKeyAccount),
                     "Without a default server URL there is no host to bind to — Keychain must stay empty")
        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }

    func testDoesNotSeedWhenDefaultServerURLHasNoParseableOrigin() {
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultAPIKey": return "bb_debug_seed_key"
            case "DefaultServerURL": return "not a url"
            default: return nil
            }
        }
        let keychain = InMemoryKeychainHelper()

        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded(keychain: keychain)

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.apiKeyAccount))
        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }

    // MARK: - No-op when debug key absent

    func testDoesNotSeedWhenDefaultAPIKeyAbsent() {
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultAPIKey": return nil
            case "DefaultServerURL": return "http://10.1.1.205:8000"
            default: return nil
            }
        }
        let keychain = InMemoryKeychainHelper()

        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded(keychain: keychain)

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.apiKeyAccount))
        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }

    // MARK: - No-op when Keychain already holds a key

    func testDoesNotOverwriteExistingKeychainKey() throws {
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultAPIKey": return "bb_debug_seed_key"
            case "DefaultServerURL": return "http://10.1.1.205:8000"
            default: return nil
            }
        }
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "user_typed_key",
            KeychainHelper.boundHostAccount: "http://existing.host:9000"
        ])

        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded(keychain: keychain)

        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.apiKeyAccount),
                       "user_typed_key",
                       "Existing user-entered key must never be overwritten by the debug fallback")
        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.boundHostAccount),
                       "http://existing.host:9000")
    }

    func testDoesNotSeedWhenKeychainHasKeyButEmptyBoundHost() {
        // Edge case: an existing (non-empty) key with a missing/empty bound
        // host should still count as "not empty" — the seed path is strictly
        // "keychain is empty", not "keychain is incomplete". Re-binding the
        // existing key is the user's responsibility and is handled by the
        // rebind flow, not by this fallback.
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultAPIKey": return "bb_debug_seed_key"
            case "DefaultServerURL": return "http://10.1.1.205:8000"
            default: return nil
            }
        }
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "user_typed_key"
        ])

        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded(keychain: keychain)

        XCTAssertEqual(keychain.readString(forKey: KeychainHelper.apiKeyAccount),
                       "user_typed_key")
        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }

    // MARK: - Atomic write semantics

    func testSeedRollsBackKeyWhenBoundHostWriteFails() {
        BuildConfig.lookup = { key in
            switch key {
            case "DefaultAPIKey": return "bb_debug_seed_key"
            case "DefaultServerURL": return "http://10.1.1.205:8000"
            default: return nil
            }
        }
        let keychain = InMemoryKeychainHelper(
            failWritesForKeys: [KeychainHelper.boundHostAccount]
        )

        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded(keychain: keychain)

        XCTAssertNil(keychain.readString(forKey: KeychainHelper.apiKeyAccount),
                     "writeAPIKeyBinding must roll back the key when the bound-host write fails")
        XCTAssertNil(keychain.readString(forKey: KeychainHelper.boundHostAccount))
    }
}
#endif
