# BinBrain iOS Security Assessment — 2026-04-13

Scope: main HEAD `9b4eba8` (worktree `dev/SECURITY`, last commit `564f71d`). Read-only review. Sibling `binbrain` server spec was not consulted; only iOS client concerns are in scope.

## Executive Summary

The client is functional but leaves the API key — the only credential protecting the backend — materially exposed in three independent ways: it is persisted in `UserDefaults` (unencrypted plist), transmitted over cleartext HTTP by default, and auto-attached to whatever base URL the user types into Settings (no scheme/host allowlist, ATS fully disabled). Any one of these is a credential-compromise pathway; together they mean that a first-run user following the default flow sends their API key in the clear on a LAN and a malicious base URL silently exfiltrates it. Response bodies and full URLs are logged at `debug` without the `%{private}` redaction marker, so `os_log` traces also leak API activity. Secondary issues: no certificate pinning, no SwiftData file-protection attribute set, no `PrivacyInfo.xcprivacy`, and QR payloads flow unsanitized into URL path components. Stored photo JPEGs in SwiftData represent low-sensitivity inventory content but share the protection class of the store. There are zero third-party SPM dependencies, which removes a class of supply-chain risk.

## Findings

| ID | Title | Severity | Likelihood | Area | File:Line | Recommendation |
|----|-------|----------|-----------|------|-----------|----------------|
| F-01 | API key stored in UserDefaults | Critical | High | Credentials | APIClient.swift:52-53, SettingsViewModel.swift:100 | Move to Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |
| F-02 | ATS fully disabled (`NSAllowsArbitraryLoads=true`) | Critical | High | Transport | Info.plist:5-9 | Remove the key; add per-domain exception only for the Pi if needed |
| F-03 | Default base URL is `http://` | High | High | Transport | APIClient.swift:46, SettingsViewModel.swift:87 | Default to `https://`; reject `http://` unless user opts in |
| F-04 | API key auto-sent to any user-configured base URL | High | Medium | AuthZ | APIClient.swift:442-444 | Bind key to a verified host fingerprint or server identity challenge |
| F-05 | No certificate pinning | Medium | Medium | Transport | APIClient.swift:64,71-73 | Add `URLSessionDelegate` pinning (SPKI) for production host |
| F-06 | Response body + full URL logged at debug without privacy redaction | Medium | High | Logging | APIClient.swift:447,463-465 | Mark interpolations `%{private}`; drop response-preview log |
| F-07 | QR payload used unsanitized as `binId` in URL paths | Medium | Medium | Input validation | ScannerView.swift:153-155, ScannerViewModel.swift:65-67, APIClient.swift:116,213,399 | Validate QR against `^[A-Za-z0-9-]{1,32}$` before assignment |
| F-08 | SwiftData store has no explicit file-protection class | Medium | Low | Data-at-rest | Bin_BrainApp.swift:26-36, PendingUpload.swift:27-64 | Set `.completeFileProtection` on the store URL after container creation |
| F-09 | Missing `PrivacyInfo.xcprivacy` manifest | Low | High | Compliance | project.pbxproj (no match) | Add privacy manifest declaring `UserDefaults` reason `CA92.1` and camera use |
| F-10 | `missingAPIKey` check bypassed on `health` (auth=false) but key still attached | Low | Low | AuthZ | APIClient.swift:95,442-444 | Don't attach `X-API-Key` when `requiresAuth == false` |
| F-11 | `createLocation` sends user text in URL query body | Low | Low | Injection | APIClient.swift:355-369 | Use JSON body; percent-encoding is correct today but fragile |
| F-12 | Debounced save persists key 500 ms after keystroke | Info | — | Credentials | SettingsViewModel.swift:110-117 | Persist only on commit, not during typing |

## Detailed Findings

### F-01: API key stored in UserDefaults (Critical)
**Evidence.** `APIClient.apiKey` reads `UserDefaults.standard.string(forKey: "apiKey")` (APIClient.swift:52-53). `SettingsViewModel.save(to:)` writes the plaintext string: `defaults.set(apiKey, forKey: "apiKey")` (SettingsViewModel.swift:100). `grep Keychain|SecItem` returns no matches in the project.
**Impact.** The app's `Library/Preferences/*.plist` contains the only backend credential in cleartext. Any iOS backup, iTunes/Finder archive, or jailbreak-level filesystem access yields the key. An attacker who gains brief device access can copy it without unlocking the Keychain.
**Recommendation.** Introduce `KeychainHelper` wrapping `SecItemAdd/Copy/Update` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrSynchronizable=false`. Migrate existing `UserDefaults` value on first launch, then delete the defaults entry. Update `APIClient.apiKey` (APIClient.swift:52) and `SettingsViewModel` (SettingsViewModel.swift:88,100) accordingly.

### F-02: ATS fully disabled (Critical)
**Evidence.** `Info.plist:5-9` sets `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` with no domain exceptions.
**Impact.** Every `URLSession` call permits plaintext HTTP and legacy TLS. Combined with F-03, this is the mechanism that allows the key to travel over the wire in the clear.
**Recommendation.** Delete the `NSAllowsArbitraryLoads` key. If local-network HTTP is required for dev, add `NSExceptionDomains` entries scoped to the Pi hostname with `NSExceptionAllowsInsecureHTTPLoads` and guard it behind a debug build configuration.

### F-03: Default base URL is cleartext HTTP (High)
**Evidence.** `APIClient.baseURL` defaults to `"http://10.1.1.206:8000"` (APIClient.swift:46); `SettingsViewModel.init` uses the same default (SettingsViewModel.swift:87).
**Impact.** Out-of-box posture is LAN-cleartext. `X-API-Key` travels on the wire in plaintext and is trivially captured by any host on the same Wi-Fi segment.
**Recommendation.** Default to `https://` and a hostname, not an IP; add a settings-time validator that rejects `http://` in release builds.

### F-04: API key auto-sent to any user-configured base URL (High)
**Evidence.** `request()` unconditionally attaches the key when `apiKey` is non-nil (APIClient.swift:442-444). `SettingsView` accepts any string into `serverURL` (SettingsView.swift; validated by SettingsViewModel.swift:87-88) and `APIClient.baseURL` reads the value at call time (APIClient.swift:46). There is no scheme/host allowlist.
**Impact.** A user tricked (or autocorrected) into entering `http://attacker.example.com` sends the current `X-API-Key` on the next request. The app provides no signal that the base URL changed — this is a silent exfiltration primitive.
**Recommendation.** Store a "bound host" alongside the key in Keychain. When `serverURL` changes, require the user to re-enter the key (or confirm with the current key via `/health` over TLS before attaching it to further requests). Additionally, enforce `https://` in release (see F-03).

### F-05: No certificate pinning (Medium)
**Evidence.** `URLSession(session:)` uses `.shared` with no `URLSessionDelegate` (APIClient.swift:64,71-73). No `SecTrustEvaluate` callsite exists.
**Impact.** A user who accepts a rogue enterprise CA, or a network attacker with a mis-issued certificate, can MITM the API including the `X-API-Key` header.
**Recommendation.** For the production host, pin the SPKI hash via a custom `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`. Keep dev/local unpinned.

### F-06: Debug logging leaks request URLs and response bodies (Medium)
**Evidence.** `logger.debug("\(method) \(urlString) ...")` (APIClient.swift:447) prints full URL including query string. `let preview = String(data: data.prefix(500), ...)` and `logger.debug("Response: \(preview)")` (APIClient.swift:463-465) emit up to 500 bytes of server response. None of these interpolations use the `%{private}` privacy marker, so `os_log` records them as `<public>` and Console.app / sysdiagnose captures them in clear text.
**Impact.** Bin IDs, item names, location names, search queries, and API error bodies are retained in unified log storage. While this is not a credential leak today, it materially widens the attack surface for device-image forensics and crosses the "minimize PII in logs" bar that the user's own CLAUDE feedback memory calls for.
**Recommendation.** Mark interpolations private: `logger.debug("\(method, privacy: .public) \(urlString, privacy: .private)")`. Drop the response-preview log entirely in release builds, or gate it on `#if DEBUG`. Never log a response body.

### F-07: QR payload unsanitized into URL path (Medium)
**Evidence.** `parent.onQRCode(payload)` passes the raw payload from `VNBarcodeObservation.payloadStringValue` (ScannerView.swift:153-155). `ScannerViewModel.qrDetected` assigns it directly: `scannedBinId = code` (ScannerViewModel.swift:65-67). `BinsListView` then feeds it into `APIClient.ingest(..., binId: binId)` which concatenates into paths such as `/bins/\(binId)/items/\(itemId)` (APIClient.swift:116,213,399). `URL(string:)` accepts `?`, `#`, and `..` segments.
**Impact.** A malicious QR code (e.g. `FOO?admin=1` or `../../bins/OTHER`) could redirect requests to a different path/endpoint on the backend, mis-associate items, or append unintended query parameters. Severity is bounded by backend routing but the client has no reason to allow it.
**Recommendation.** Validate the QR payload in `ScannerViewModel.qrDetected` with a strict regex (e.g. `^[A-Za-z0-9_-]{1,32}$`) before assignment; reject otherwise. Percent-encode path components in `APIClient` using `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)` as defence-in-depth.

### F-08: SwiftData store lacks explicit file-protection attribute (Medium)
**Evidence.** `sharedModelContainer` is built with `ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)` (Bin_BrainApp.swift:26-34). No `FileProtectionType` is set and no `FileManager.setAttributes([.protectionKey: .complete], ...)` call exists (`grep FileProtection` returns no matches in the app target). `PendingUpload` persists full JPEG bytes (`var jpegData: Data`, PendingUpload.swift:31).
**Impact.** The store inherits the app's default protection class. If the device is seized while unlocked (or cold-booted without first-unlock on an older data-protection class), queued-but-not-yet-uploaded photos are readable. Photo content is low-sensitivity here (bin contents) but the queue is bounded in size only by upload success.
**Recommendation.** After resolving the container URL, call `FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)` on the store file and its `-wal`/`-shm` siblings. Cap the pending-upload queue size and age.

### F-09: Missing PrivacyInfo.xcprivacy (Low)
**Evidence.** `grep PrivacyInfo` matches nothing in the project; only `INFOPLIST_KEY_NSCameraUsageDescription` is set (project.pbxproj:405,439). `UserDefaults` is used (required-reason API).
**Impact.** App Store submissions after May 2024 fail validation without the manifest. Not a security issue per se but blocks any future public release.
**Recommendation.** Add `PrivacyInfo.xcprivacy` declaring camera, `UserDefaults` (reason code `CA92.1` — access to the app's own defaults), and file timestamp APIs if used. Include it in the app target's Copy Bundle Resources.

### F-10: `X-API-Key` attached on unauthenticated endpoints (Low)
**Evidence.** `request()` gates the `missingAPIKey` error on `requiresAuth` (APIClient.swift:422-427) but then unconditionally attaches the header (APIClient.swift:442-444). `health()` is the only caller with `requiresAuth: false` today (APIClient.swift:95).
**Impact.** The health endpoint receives the key unnecessarily — and critically, `testConnection` (SettingsViewModel.swift:125-133) calls `health()` against whatever URL the user just typed. Combined with F-04, this is the most likely exfiltration trigger in practice: users hit "Test Connection" right after editing the URL.
**Recommendation.** Inside `request()`, wrap the header attachment in `if requiresAuth, let apiKey { ... }`.

### F-11: `createLocation` uses URL-encoded form body built from query components (Low)
**Evidence.** `APIClient.createLocation` builds `URLComponents.queryItems` and uses `components.percentEncodedQuery` as the body with `Content-Type: application/x-www-form-urlencoded` (APIClient.swift:355-368).
**Impact.** Functionally correct and percent-encoded, but the pattern is fragile and inconsistent with the rest of the client (which uses JSON or multipart). A future refactor could easily reintroduce an injection bug.
**Recommendation.** Switch to a JSON body with `JSONEncoder`, matching `assignLocation` / `updateItem`.

### F-12: Debounced save writes the API key 500 ms after each keystroke (Info)
**Evidence.** `SettingsViewModel.debouncedSave` persists `apiKey` to UserDefaults on every pause (SettingsViewModel.swift:110-117, writing at line 100).
**Impact.** Compounds F-01 by creating multiple partial-key values in the defaults plist during entry. Minor.
**Recommendation.** Once the key lives in Keychain, write it only on an explicit Save action.

## Compliance Notes

Not currently in scope for HIPAA/GDPR (personal project, no declared PII). However, F-01, F-02, F-03, F-05, F-06, and F-08 would each block any regulated deployment. F-09 blocks App Store submission independent of regulatory scope. There are no third-party SPM dependencies (no `Package.resolved` in the worktree), which avoids the supply-chain findings class entirely.

## Suggested Next Steps for ARCHITECT

1. **F-01 + F-02 + F-03 together** — ship one change: Keychain migration, remove `NSAllowsArbitraryLoads`, default to `https://`. These form the credential-on-wire chain and must be remediated as a unit.
2. **F-04 / F-10** — refactor `APIClient.request()` to attach `X-API-Key` only when `requiresAuth` is true and the current `baseURL` matches a user-confirmed host.
3. **F-06** — audit every `logger.debug/error/warning` call; add `privacy: .private` to URLs, IDs, errors, and bodies; delete the response-preview log.
4. **F-07** — add QR payload validation in `ScannerViewModel.qrDetected` and percent-encode path components in `APIClient`.
5. **F-08 + F-09** — set `.completeFileProtection` on the SwiftData store and add `PrivacyInfo.xcprivacy`.
