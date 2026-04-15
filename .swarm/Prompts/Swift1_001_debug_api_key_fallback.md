# Swift1 — Debug-only API key fallback

**Branch:** `feature/debug-api-key-fallback` off `main`
**Priority:** Low (DX polish; must not weaken production security posture)

## Problem

After a fresh install (or simulator reset) the Keychain entry written under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with `kSecAttrSynchronizable = false` is gone, so the dev has to re-type the API key every time. This is purely a developer-experience papercut during local iteration.

## Goal

Introduce a **DEBUG-only** fallback that seeds the API key from a build-time source when Keychain is empty, **without** breaking any of the F-04 host-binding guarantees validated in the 2026-04-15 aegis re-audit.

## Must-haves (non-negotiable)

1. **`#if DEBUG` around every line of new code.** Release/TestFlight binaries must behave identically to today. Add a test that proves the symbol is absent in non-DEBUG compile or, if that's impractical, an `#error` guard preventing the fallback path being reached when `DEBUG` is undefined.
2. **Respect host-binding (F-04).** Any seeded key must go through the same `commitAPIKey` / `writeAPIKeyBinding` atomic path (`SettingsViewModel.swift:156-170`, `KeychainHelper.swift:247-256`) so `apiKeyBoundHost` is written alongside the key. A seeded key with no bound host must NOT be accepted — `shouldAttachKey` (`APIClient.swift:491-512`) would refuse to attach it anyway, so verify end-to-end.
3. **No key material in the repo.** The fallback reads from:
   - a `.xcconfig`-derived `BuildConfig` value (preferred; same mechanism as `BuildConfig.defaultServerURL`), or
   - a process environment variable read at launch (fallback for local-only).
   The `.xcconfig` file must be `.gitignore`d and a `.xcconfig.example` committed in its place.
4. **Fallback fires only when Keychain is empty.** Never overwrite an existing Keychain-stored key.
5. **Fallback host defaults to `BuildConfig.defaultServerURL`'s origin.** If no default, do nothing (don't seed a key bound to `http://10.1.1.206:8000` silently).

## TDD plan (RED → GREEN → REFACTOR)

Write failing tests first, in the test target, for:

- Keychain empty + `BuildConfig.debugAPIKey` set + `BuildConfig.defaultServerURL` set → key and bound host are both present after app launch.
- Keychain empty + `BuildConfig.debugAPIKey` set + `BuildConfig.defaultServerURL` absent → Keychain stays empty.
- Keychain already has a key → fallback is a no-op (existing key untouched).
- Release/non-DEBUG build (simulate via `#if DEBUG` guard in a test helper) → fallback symbol is unreachable.

## Out of scope

- Any change to production key entry UI.
- Any change to `shouldAttachKey` or `KeychainHelper` accessibility classes.
- iCloud Keychain sync (explicitly `kSecAttrSynchronizable = false` stays).

## References

- `Bin Brain/Bin Brain/APIClient.swift:64-81, 491-512` — baseURL fallback and host-binding gate
- `Bin Brain/Bin Brain/KeychainHelper.swift:135-195, 247-256` — accessibility, migration, atomic write
- `Bin Brain/Bin Brain/SettingsViewModel.swift:115-170` — commit + rebind paths
- `thoughts/shared/agents/aegis/security-reaudit-2026-04-15.md` — current security state (F-04 CLOSED, must stay closed)

## Completion

Open a PR titled `feat(debug): seed API key from BuildConfig in DEBUG builds`. Push `ARCHITECT TASK COMPLETED: Pull Request #<n>` to the Architect pane when ready for review.
