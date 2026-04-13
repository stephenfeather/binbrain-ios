// KeychainHelper.swift
// Bin Brain
//
// Facade over SecItem* for storing small text secrets (API keys, etc.)
// in the iOS Keychain. Conforms to KeychainReading so tests can inject
// an in-memory double.

import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "com.binbrain.app", category: "Keychain")

// MARK: - Protocol

/// Read and write text secrets in a Keychain-like store.
///
/// Production code uses `KeychainHelper.shared`; tests inject
/// `InMemoryKeychainHelper` to avoid touching the real Keychain.
protocol KeychainReading: Sendable {
    /// Returns the stored value for `key`, or `nil` if absent.
    func readString(forKey key: String) -> String?

    /// Writes `value` under `key`, overwriting any existing entry.
    func writeString(_ value: String, forKey key: String) throws

    /// Removes the entry for `key`. No-op if the entry is absent.
    func removeValue(forKey key: String) throws
}

// MARK: - Errors

/// Errors thrown by `KeychainHelper` when `SecItem*` fails unexpectedly.
enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

// MARK: - KeychainHelper

/// Stores text secrets in the iOS Keychain under a single service tag.
///
/// All entries use `kSecClassGenericPassword` with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
/// `kSecAttrSynchronizable = false` — never syncs to iCloud,
/// unavailable before first unlock after reboot.
struct KeychainHelper: KeychainReading {

    /// Shared instance used by production code.
    static let shared = KeychainHelper(service: "com.binbrain.app")

    /// The service tag scoping all entries (maps to `kSecAttrService`).
    let service: String

    /// Creates a helper with the given service tag.
    ///
    /// - Parameter service: The Keychain service identifier. Tests can
    ///   pass a unique value (e.g. `UUID().uuidString`) to isolate state.
    init(service: String) {
        self.service = service
    }

    /// Returns the stored string for `key`, or `nil` if absent or unreadable.
    func readString(forKey key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            logger.error("readString status=\(status) key=\(key, privacy: .public)")
            return nil
        }
    }

    /// Writes `value` under `key`, replacing any existing entry.
    func writeString(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        // TODO(#10): SecItemAdd is a required-reason API under Apple's 2024
        // rules. Privacy manifest (PrivacyInfo.xcprivacy) is tracked in #10.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                logger.error("SecItemAdd status=\(addStatus) key=\(key, privacy: .public)")
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            logger.error("SecItemUpdate status=\(updateStatus) key=\(key, privacy: .public)")
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Removes the entry for `key`. No-op when the entry is absent.
    func removeValue(forKey key: String) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            logger.error("SecItemDelete status=\(status) key=\(key, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Private

    /// Base query dictionary scoped to `service` + `key` (as account).
    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

// MARK: - Migration

extension KeychainHelper {

    /// The `UserDefaults` key previously used to persist the API key.
    static let legacyAPIKeyDefaultsKey = "apiKey"

    /// The Keychain account used for the API key.
    static let apiKeyAccount = "apiKey"

    /// Moves the API key from `UserDefaults` into the Keychain on first launch.
    ///
    /// Idempotent and safe to call on every launch:
    /// - Reads `UserDefaults.standard.string(forKey: "apiKey")`.
    /// - If present and non-empty and the Keychain does **not** already hold a
    ///   value, writes the value to the Keychain and then clears the
    ///   `UserDefaults` entry.
    /// - If the Keychain already holds a value, leaves `UserDefaults` untouched
    ///   and does not overwrite.
    /// - If the write fails, `UserDefaults` is preserved so the next launch
    ///   can retry.
    ///
    /// - Parameters:
    ///   - keychain: The Keychain facade to write into. Defaults to `.shared`.
    ///   - defaults: The `UserDefaults` suite to read/clear. Defaults to `.standard`.
    static func migrateAPIKeyFromUserDefaultsIfNeeded(
        keychain: KeychainReading = KeychainHelper.shared,
        defaults: UserDefaults = .standard
    ) {
        guard let legacy = defaults.string(forKey: legacyAPIKeyDefaultsKey),
              !legacy.isEmpty else {
            return
        }

        if let existing = keychain.readString(forKey: apiKeyAccount), !existing.isEmpty {
            // Keychain already authoritative. Clear legacy entry to finish migration.
            defaults.removeObject(forKey: legacyAPIKeyDefaultsKey)
            return
        }

        do {
            try keychain.writeString(legacy, forKey: apiKeyAccount)
            defaults.removeObject(forKey: legacyAPIKeyDefaultsKey)
        } catch {
            logger.error("API key migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
