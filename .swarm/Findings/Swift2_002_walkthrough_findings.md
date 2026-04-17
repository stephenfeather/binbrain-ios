# Swift2_002 Walkthrough — Findings Log

Source session: systematic iOS app walkthrough driven by ARCHITECT (binbrain:0.0),
observed by Swift dev (binbrain:0.2), backend in binbrain:0.1. No code changed.
All items below are INVESTIGATION NOTES for follow-up tasks (Swift2_003 etc).

## #1 — Locations: no edit/rename UI (UX gap)
- Phase step 1.4 not testable. Locations list has create, no edit affordance.
- Follow-up: add row-tap → rename sheet, match Bins detail pattern.

## #2 — (retracted) Missing Console logs
- False alarm: subsystem filter was `com.binbrain`; actual subsystem is
  `com.binbrain.app`. Process issue only.

## #3 — Scan-bin → scan-item transition cue (UX)
- Header flips `Scan Bin` ↔ `Scan Item` and shutter overlay appears only after
  a valid QR (BinsListView.swift:174 + ZStack at 151). Working, but the cue
  is subtle; users miss it.
- Follow-up: add haptic on QR detection + visible state banner.

## #4 — Blur gate always fails (bug, do NOT fix yet)
- `QualityGates.swift:19` — `kBlurVarianceThresholdAt1024: Double = 2.0`,
  scaled linearly by `shortest / 1024`. Not user-adjustable
  (`SettingsViewModel.swift` only persists `serverURL` + `similarityThreshold`).
- `grayscaleBuffer()` at `QualityGates.swift:372` renders 8-bit gray, then
  `vImageConvert_Planar8toPlanarF(&src, &dest, 0, 1, flags)` (L414) normalizes
  pixels into `[0,1]` (inverted, but variance is sign-invariant).
- On `[0,1]`-normalized inputs, Laplacian variance for a sharp photo is
  ~0.01–0.1 — a threshold of 2.0 is ~20–100× too large.
- Scaling compounds the problem at >1024 px (e.g. 4032 px iPhone photo →
  effective threshold ≈ 7.88).
- Follow-up: log variance at debug, empirically calibrate, consider a
  Settings toggle or `BuildConfig`-driven value.
  
(Stephen: I would like a settings toggle. We could deactivate/hide it after we are done debugging)

## #5 — On-device pre-classifier picks background (ML quality)
- Pencil-on-carpet photo → labels {material, textile, tool}; 2/3 are carpet.
- Related memory `project_photo_subject_is_items.md`: subject is the item,
  not the bin scene — current classifier not trained on that premise.
- Follow-up: tracked in `thoughts/shared/designs/coreml-preclassification-scope.md`.

## #6 — Item created with `bin_id=None` (server bug)
- Backend log: `event=item_create request_id=bd2bad4a… item_id=1 bin_id=None`
  despite the flow originating from BIN-0003.
- Follow-up is backend (binbrain:0.1).

## #7 — YOLOE background reload crash (server bug)
- Backend thread `reload_classes` raised `PermissionError: /models`; model path
  not writable in the Docker container.
- Follow-up is backend.

## #8 — GET /bins/{id} decode failure ("data could not be read")
- iOS `GetBinResponse` (`APIModels.swift:172`) and `PhotoRecord` (`APIModels.swift:62`)
  match OpenAPI `docs/openapi.yaml` L50-59, L227-241 exactly.
- Server omitted required `photo.path` field → Foundation `keyNotFound`.
- ARCHITECT PIVOT: server is correct — F-10 security control strips
  filesystem `path`. Real fix: spec + iOS rename `path` → `url` pointing at
  `/photos/{id}/file`. Do NOT patch now; coordinate with backend spec change.

## #9 — Model-select intermediate state is visually weak (UX)
- Tap path: `SettingsView.swift:187-210` → `SettingsViewModel.selectModel()`
  (`SettingsViewModel.swift:333-342`). `isSwitchingModel` does toggle; rows
  are `.disabled` and a bottom-of-section `ProgressView` + "Switching model…"
  appears at L212-217 — but it's not inline with the tapped row, and there
  is no haptic/toast on success.
- Follow-up: inline per-row spinner, haptic + toast on 200.

(Stephen: Clarification. The rows were not greyed out. The entire list was greyed out as the switch was being processed)

## #10 — Test Connection surfaces raw NSURL/ATS text (UX)
- APIClient maps thrown errors via `error.localizedDescription` →
  iOS-generic ATS messages leak to the user.
- Follow-up: map common `NSURLError` codes to friendly messages in APIClient
  or Settings.

## #11 — ATS exception hardcoded to 10.1.1.205 in Info-Debug.plist (deploy)
- Brittle on LAN IP change. Follow-up: use `.local` mDNS name (matches
  SPEC.md) or drive via `BuildConfig`.

## #12 — apiKey TextField desync after host revert (bug)
- `SettingsViewModel.swift:115-120` reads the raw Keychain key at init; the
  TextField binds directly to `apiKey`, so asterisks show whenever *any* key
  is stored — independent of binding validity.
- F-04 attach gate (`APIClient.shouldAttachKey`, L491-512) compares
  `normalizedOrigin(baseURL)` to `boundHost`. When they diverge the header
  is silently stripped; the UI never reflects that.
- `keyExistsButUnboundForCurrentHost()` at L272-279 exists but is only
  consulted by `testConnection()` — not by the field itself.
- Follow-up options:
  - Observe `connectionStatus`; render inline "Key not bound to this host —
    tap to rebind" under the TextField.
  - Clear the displayed asterisks (not the stored value) when the binding
    is invalid.
  - Auto-invoke `rebindKey()` after host commit when a stored key exists.

## #13 — testConnection reports "not authed" while data calls succeed (UX bug)
- `SettingsViewModel.testConnection()` (L198-224) calls
  `apiClient.health()` with default `probeWithCurrentKey=false`.
- `APIClient.health()` (`APIClient.swift:132-142`) passes
  `requiresAuth: false, probeWithCurrentKey: false`.
- `shouldAttachKey()` (L491-512): `if probe return true; guard requiresAuth
  else return false` — the `/health` probe never sends `X-API-Key`.
- Server therefore returns `auth_ok: nil` → `.none` branch in
  `testConnection` → either `.connectedNoKey` or
  `.connectedKeyNotBoundToHost(canRebind: true)`.
- Meanwhile `GET /bins` and `GET /locations` default to `requiresAuth: true`,
  pass the gate (binding intact), and succeed. Divergence.
- This is F-04 design (no key off-host on routine probe), but the UX hides
  the reason.
- Follow-up options:
  - Two-pass: health() → if `.none`, auto-retry with `probeWithCurrentKey: true`
    and display true `auth_ok`.
  - Probe via a real data endpoint (same gate as real calls).
  - Surface `.connectedNoKey` vs "stripped by policy" as distinct states.

## Process / Swarm notes
- Subsystem is `com.binbrain.app` — document for future Console filter users.
- `log stream --device` does NOT exist; Console.app is the only supported path
  for physical-device subsystem log streaming from the CLI side.
- Pre-existing "Office" + "Medical Storage" locations in backend DB at the
  start of Phase 1 were created by the peer during setup — not a stale
  cache. Clarify DB-seed vs walkthrough-emitted data for future runs.
