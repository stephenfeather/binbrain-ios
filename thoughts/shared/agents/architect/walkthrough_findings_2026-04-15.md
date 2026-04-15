# Bin Brain iOS — Systematic Walkthrough Findings

**Date:** 2026-04-15
**Architect:** Claude (tmux `binbrain:0.0`)
**Backend Dev:** tmux `binbrain:0.1` (`~/Development/binbrain/binbrain`)
**Swift Dev:** tmux `binbrain:0.2` (`~/Development/binbrain-ios`)
**Human Overseer:** Stephen (driving physical iPhone 15 Pro Max paired to Xcode)
**Server:** `http://10.1.1.205:8000` (Docker `binbrain_api`, 47h+ uptime)

## Scope

Systematic walkthrough of the four-tab app surface (Locations, Bins, Search, Settings) against the current binbrain API server, with backend dev observing container/log state and Swift dev correlating iOS Console (subsystem `com.binbrain.app`).

Starting DB state: empty except one pre-existing API key.

## Execution Summary

| Phase | Status | Notes |
|-------|--------|-------|
| 1 — Locations | Complete (partial) | Create + list worked; rename step blocked by missing UI/endpoint. |
| 2 — Bins | Complete (with blocker bypass) | QR scan + photo upload + classification + confirm flow exercised end-to-end. Blur gate bypassed in-UI. Bin detail view fails to render. |
| 3 — Search | **Skipped** | DB had 1 orphaned item + broken bin detail; compound failures would muddy signal. |
| 4 — Settings | Complete | Host/key/models/image-size/search-threshold/upload-queue all inspected. |

## Findings (canonical numbering)

### P0 — Architectural gaps or blockers

#### Finding #1 — Edit-location endpoint + UI missing (cross-repo)
- **Observation:** No edit/rename UI in Locations tab.
- **Server verification:** `api/app/routes/locations.py` exposes only `GET`, `POST` (admin), `DELETE` (admin). No `PATCH/PUT /locations/{id}`. `repository.update_location` / `rename_location` do not exist.
- **Fix:** (a) Server — add `PATCH /locations/{id}` (body `{name?, description?}`, admin-guarded, `200/404/409`). Add `repository.update_location`. (b) iOS — add edit screen + `APIClient` method.
- **Prompt plan:** Dev2_003 (server), Swift2_003 (iOS).

#### Finding #2 — Bin-creation endpoint missing (product decision pending)
- **Observation:** Bin is created lazily — iOS scans a QR, server only materializes a bin row when `POST /ingest` arrives with that `bin_id`.
- **Server verification:** API surface has `GET /bins`, `GET /bins/{id}`, `POST /bins/{id}/add`, `DELETE /bins/{id}/items/{item_id}`, `PATCH /bins/{id}/items/{item_id}`, `PATCH /bins/{id}/location`. No `POST /bins`, no `PATCH /bins/{id}` for rename. BIN-0003 was pre-seeded.
- **Product question open:** Is this intentional (print-and-scan only, bins provisioned externally) or an omission?

#### Finding #3 (was #7) — YOLOE `reload_classes` silently crashes; new classes never load
- **Observation:** `POST /classes/confirm` responded 200 `class=Pencil added=True`. Background Thread-49 then crashed on `os.mkdir('/models')` with `PermissionError [Errno 13]` — `/models` doesn't exist in container, app user (`uid=100`) lacks write at `/`. HTTP had already returned 200, so the failure is invisible to the client.
- **Impact:** Newly confirmed classes are NOT loaded into the live detection model. Next `/detect` call will not recognize `Pencil`.
- **Fix:** (a) Dockerfile/compose — create `/models` dir owned by the app user at image build, or bind-mount a host volume, (b) set `MODEL_DIR` env var to a writable path like `/app/models`, (c) surface reload failures (status endpoint or log alert), (d) optionally fail `/classes/confirm` if reload fails.

#### Finding #6 — Orphaned items (bin association step missing)
- **Observation:** `POST /items` returned 200 with `item_id=1, bin_id=None`. No follow-up `POST /bins/BIN-0003/add` or `/associate` fired. DB verification: `items` has row, `bin_items` join is empty.
- **Schema:** Linkage is `bin_items(bin_id, item_id, confidence, quantity)` — NOT photo-derived. `fetch_bin_items()` JOINs `bin_items → items`.
- **Fix (iOS first, simpler):** SuggestionReviewViewModel confirm flow must `POST /bins/{bin_id}/add` after `/items` succeeds.
- **Alternative (server API change):** `/items` accepts `bin_id` and associates atomically. Bigger contract change; defer unless product wants it.

#### Finding #8 — `GET /bins/{id}` photo shape violates contract; iOS decode fails (3-layer bug)
- **Observation:** iOS BIN-0003 detail screen shows standard Foundation `DecodingError`: "The data couldn't be read because it is missing."
- **Raw response:** `{"version":"1","bin_id":"BIN-0003","location_id":null,"location_name":null,"items":[],"photos":[{"photo_id":3}]}`
- **Root cause:** iOS `PhotoRecord` requires `photoId` + `path`. Server allowlist `_PUBLIC_PHOTO_FIELDS = frozenset({'photo_id'})` at `api/app/routes/bins.py:37` strips `path` **by design** (F-10 security control — never expose internal filesystem paths).
- **Secondary finding:** `GET /bins/{bin_id}` has no Pydantic `response_model`; OpenAPI publishes empty schema for this route. Spec-level check passes trivially.
- **Resolution (cross-repo API contract change):**
  - Spec: drop `path` from `PhotoRecord`; add `url` pointing at `/photos/{id}/file` (endpoint already exists).
  - Server: allowlist becomes `{photo_id, url}`; build the URL server-side.
  - Server: add `response_model` so OpenAPI schema is truthful.
  - iOS: rename `PhotoRecord.path` → `url`.
- **Historical context:** photo gallery was cut from v1 due to this exact `path` exposure problem. This resolution unblocks v2.

### P1 — UX / iOS-side bugs

#### Finding #4 — Blur gate rejects every photo
- **Observation:** Stephen reported 100% blur-rejection on device. Memory-confirmed pattern.
- **Root cause (from code read, not patched):** `Bin Brain/Bin Brain/Services/Pipeline/QualityGates.swift`
  - Hardcoded threshold `kBlurVarianceThresholdAt1024 = 2.0` at line 19 (scaled by `shortestSide/1024`).
  - Pipeline normalizes pixels to `[0,1]` at line 414 (`vImageConvert_Planar8toPlanarF`, `maxFloat=0, minFloat=1`).
  - Laplacian kernel `[0,1,0,1,-4,1,0,1,0]` + `vDSP` variance.
  - On `[0,1]` inputs, sharp-photo variance is typically `0.01–0.1`. Threshold 2.0 is 20–100× too large — **nothing passes**.
- **Likely origin:** threshold tuned against `[0,255]` pixel scale (OpenCV convention) and never re-calibrated after normalization change.
- **Fix plan:** (a) instrument — emit computed variance per photo, (b) take 5 sharp + 5 blurry samples on the actual device, (c) set threshold empirically, (d) expose in Settings alongside `similarityThreshold` (same `UserDefaults` pattern per existing code).
- **Walkthrough workaround used:** Stephen bypassed in-UI to continue.

#### Finding #5 — On-device classifier biased toward background
- **Observation:** Photo of a pencil on carpet returned on-device options: `material`, `textile`, `tool`. Two of three are carpet false positives.
- **Hypothesis:** No subject/salience isolation before classification; top-N dominated by dominant-area pixels. Model may be too coarse for item cataloging.
- **Cross-reference:** `thoughts/shared/designs/coreml-preclassification-scope.md` — design may need a salience/crop preprocessing stage.

#### Finding #9 — Model-select provides no per-row feedback
- **Observation:** Tapping a model in Settings dims all rows (via `isSwitchingModel`), shows a "Switching model…" ProgressView at the *bottom* of the section (easy to miss), then silently updates the checkmark on success. Server traffic confirmed correct: `POST /models/select` → 200 in 1–11ms.
- **Code:** `SettingsView.swift:187–210` ForEach with `.disabled(isSwitchingModel)` on all rows; ProgressView at `L212–217` outside the ForEach.
- **Fix:** move progress inline next to the tapped row; add haptic + success toast on 200.

#### Finding #10 — Test Connection leaks raw ATS error text
- **Observation:** Entering `http://foobar.baz:8001` and tapping Test Connection surfaces "The resource could not be loaded because the app transport security policy requires the use of a secure connection" verbatim.
- **Context:** ATS config is tightened per F-02 remediation; only `10.1.1.205` is in `NSExceptionDomains` in `Info-Debug.plist`. Blocking is correct; message is not.
- **Fix:** map `NSURLError`/ATS codes to friendly copy like "That host isn't allowed by this build. Use a whitelisted host, or rebuild with it added to `Info-Debug.plist`."

#### Finding #11 — ATS exception domain hardcoded to one LAN IP
- **Observation:** `Info-Debug.plist:13` hardcodes `10.1.1.205` as the only HTTP exception domain.
- **Impact:** DHCP change or different LAN breaks Test Connection for legitimate hosts.
- **Fix options:** (a) use `raspberrypi.local` mDNS name (matches SPEC.md intent), (b) drive from build config, (c) production `Info.plist` with HTTPS-only + mkcert CA trust (proper F-02 completion).

#### Finding #12 — API key UI desync on host change (F-04 state leakage)
- **Observation:** After changing host to `foobar.baz`, reverting to `10.1.1.205:8000`, and re-visiting Settings: key field shows asterisks (populated) but a slashed-key icon and Test Connection both report "no api key configured". GET /bins and /locations *did* succeed via APIClient's attach gate — so the binding state depends on which check you look at.
- **Root cause (from code read):**
  - `SettingsViewModel.swift:115–120` — `apiKey = keychain.readString(...) ?? BuildConfig.defaultAPIKey ?? ""`. TextField binds raw Keychain value regardless of binding validity.
  - `boundHostAccount` is a **separate** Keychain entry, recorded at last `commitAPIKey()`.
  - `save(to:)` debounces only `serverURL` + `similarityThreshold`, never touches `apiKey` / `boundHost`.
  - `APIClient.request()` attach gate: strips `X-API-Key` when `normalizedOrigin(baseURL) != boundHost`.
  - `keyExistsButUnboundForCurrentHost()` (L272–279) is the correct signal, but the TextField never observes it.
- **Fix (recommended):** (a) auto-`rebindKey()` when host commit matches a prior bound origin AND Keychain key exists, (b) status chip under the field ("Key bound" / "Key unbound — tap to rebind" / "No key stored") so the auto-rebind has visible receipt. Avoid clearing the field — users will think it was deleted.

#### Finding #13 — Test Connection is "lying" (F-04 design + UX gap)
- **Observation:** Test Connection reports "not authed" while GET /bins and /locations succeed with 200.
- **Root cause (from code read):**
  - `testConnection()` calls `apiClient.health()` with `probeWithCurrentKey: false` (default).
  - `shouldAttachKey()` in `APIClient.swift:491–512` only attaches the key when `requiresAuth=true` OR `probeWithCurrentKey=true` — so `/health` probe always omits the key.
  - Server's auth-probe extension echoes `auth_ok` only when a key is supplied → response has `auth_ok=nil` → iOS falls through to "not authed" branch.
  - Meanwhile real endpoints use `requiresAuth=true`, attach gate evaluates fine against `boundHost`, requests succeed.
- **Why it's "by design":** F-04 policy prevents routine probes from leaking the key off-host; rebind flow explicitly opts in via `probeWithCurrentKey=true`.
- **Fix (recommended):** In `testConnection`, first call `/health` unauth'd (reachability). If reachable and a stored key exists, auto-retry once with `probeWithCurrentKey=true` and report actual `auth_ok`. Combine with #10/#12 copy so the single Test Connection result answers the user's real question ("is everything OK?") with: "Host reachable, key bound" / "Host reachable, key unbound — tap to rebind" / "Host reachable, no key stored" / "Host unreachable".

### P2 — Minor / UX polish

#### Finding #3-UX (was original #3) — Scan-bin → scan-item transition cue too subtle
- Header toggles from "Scan Bin" to "Scan Item" as the success signal. Functionally correct; visually missed by the user on first try.
- **Fix:** stronger cue on transition — header animation, haptic, brief toast/banner "Bin BIN-0003 loaded — now scan an item."

#### Vision Model list mixes non-vision models
- `gemma2`, `llama3.1`, `llama3` appear under the "Vision Model" section without filtering. Not a validation bug (selection works), but misleading.
- **Fix:** filter the Settings model list to vision-capable models only, or group with a visible separator.

### P0-Process — Finding #14: Security-audit regressions escaped TDD because tests don't cover layer boundaries

**Observation (2026-04-15 retrospective, after walkthrough):** The cataloging pipeline worked reliably pre-audit. F-02 (ATS tightening), F-04 (host-bound API key), and F-10 (photo path confinement) landed — and most of the 13 walkthrough findings trace directly back to them. TDD was in place; it passed; bugs shipped anyway.

**Root cause — tests were correct at the unit level but blind at the boundaries:**

| Finding | What the unit test covered | What actually broke |
|---------|----------------------------|---------------------|
| #4 blur gate | Synthetic pixel array + hardcoded threshold | Pipeline normalized to `[0,1]`; threshold calibrated for `[0,255]` is 20–100× too large. |
| #6 orphan items | `APIClient.createItem` called `/items` (mocked 200) | End-to-end cataloging flow was never wired to also call `/associate`. Unit tests had no reason to notice the missing second call. |
| #8 photo path | iOS decoded a fixture captured before F-10 landed | Server stopped emitting `path`; fixture was never regenerated. iOS tests kept passing against stale data. |
| #12 key UI desync | `commitAPIKey()`, `rebindKey()`, `keyExistsButUnboundForCurrentHost()` all tested in isolation | Full user sequence (commit host A → change to B → revert to A → observe UI) was never exercised. The displayed state lies. |
| #13 `testConnection` | `APIClient.health()` returned what the mock returned | Real flow: F-04 strips key on non-auth probe, so `auth_ok` is always nil — UI always reports "not authed" even when real endpoints succeed. |

**Pattern:** every regression is at a **contract or sequence boundary** — iOS ↔ server, Swift ↔ plist/config, pure-logic ↔ real-device-pixels, ViewModel method ↔ multi-step user action. Unit TDD isolates components by design; security audits change contracts at exactly those isolated seams.

**Secondary pattern:** security findings landed **without paired integration tests** proving the old happy path still worked. F-04's attach-gate was correct security-wise and correct unit-test-wise; the UX consequence (Test Connection lies, key UI desyncs) had no test to fail.

**Fix — test-architecture investments, not more unit tests:**

1. **Cross-repo contract test.** iOS CI pulls `binbrain/docs/openapi.yaml`, runs every decoder against the spec's example responses, fails on shape drift. Would have caught #8 the day F-10 landed.
2. **Calibrated-constants policy.** Any threshold tuned to real-world data (blur variance, classifier confidence, similarity cutoff) gets a dated sample artifact checked in (`tests/fixtures/calibration/blur_samples_2026-04-15.json`). The test asserts the constant still matches the artifact's recomputed value. Forces re-calibration when the pipeline upstream changes (e.g., a normalization swap).
3. **Sequence-level ViewModel tests.** For every user journey (host change + revert, catalog a photo end-to-end, connect → disconnect → reconnect), write one test that runs the full method sequence against a non-mocked ViewModel graph. Unit tests don't go away; they gain a companion.
4. **Security-finding template requires a happy-path regression test.** When closing F-N, the PR must include an integration test that exercises the pre-audit workflow the finding touched, to prove the fix didn't break it. No check-in until that test is added and passing.

**Why this belongs in the findings report rather than just the next prompt:** the above isn't a single-task fix. It's a standing process change that should apply to every future security remediation and every future pipeline change. Swift2_003 can't absorb it; it needs its own track (possibly Swift3_001 / Dev3_001 for the CI-level contract test).

**Not the fault of TDD or the developer:** the TDD cycle was followed correctly each time. What's missing is the next layer up — contract tests between services, sequence tests for user flows, and an explicit policy that security PRs carry regression coverage.

## Working-as-designed (no action)

- **F-02 ATS tightening** — invalid host correctly blocked before request leaves device. No server traffic observed. ✓
- **F-04 host-bound key** — key stripped when `baseURL` host differs from `boundHost`. ✓
- **Container + DB stability** — server ran for 47h+ without restart; `/health` consistently 200 in ~17μs LAN. ✓
- **`/health` unauth design** — intentional; optional auth-probe extension echoes `auth_ok` only when a key is supplied.

## Cross-repo work queue (for prompt drafting)

### Server (binbrain) — Dev2_003 and siblings
1. `PATCH /locations/{id}` endpoint + `repository.update_location` (Finding #1).
2. Resolve bin-creation product question (Finding #2); if endpoint needed, add `POST /bins`.
3. Fix `/models` container permissions + surface YOLOE reload failures (Finding #3).
4. Add `response_model` for `GET /bins/{bin_id}`; expand photo allowlist to `{photo_id, url}` (Finding #8).

### iOS (binbrain-ios) — Swift2_003 and siblings
1. Add location edit UI + `APIClient.updateLocation` (Finding #1, paired with server).
2. Fire `POST /bins/{bin_id}/add` after `/items` in SuggestionReviewViewModel confirm flow (Finding #6).
3. Rename `PhotoRecord.path` → `url` (Finding #8, paired with server).
4. Blur gate: instrument → calibrate → set threshold → (optionally) expose in Settings (Finding #4).
5. CoreML pre-classification: add salience/crop preprocessing before top-N (Finding #5).
6. Inline per-row spinner + haptic/toast on model-select (Finding #9).
7. Friendly ATS/URLError copy in Test Connection (Finding #10).
8. mDNS / build-config–driven ATS exception (Finding #11).
9. Auto-rebind on host revert + status chip under key field (Finding #12).
10. Unified Test Connection logic: reachability + auth probe with current key, combined copy (Finding #13).
11. Stronger scan-mode transition cue (Finding #3-UX).
12. Filter Settings model list to vision-capable (minor).

## Finding #4-REDESIGN — Salience-aware blur detection (follow-up)

Added after Swift2_003 instrumentation + Stephen's calibration pass.

- **Status:** OPEN — out of scope for Swift2_003. New prompt to follow.
- **Calibration result (2026-04-15):** Stephen collected n=7 device samples across fuzzy + clear captures. The whole-frame Laplacian-variance metric does NOT separate the two distributions — means are inverted (fuzzy mean `0.00108` > clear mean `0.00066`) and distributions overlap. No scalar threshold on this metric works.
- **Root cause (hypothesis, pairs with Finding #5):** The whole-frame Laplacian is dominated by background texture. When the subject of interest is ~5% of the frame (item on carpet / workbench), a blurry subject over a sharp background yields a high variance; a sharp subject over a uniform background yields a low one. The signal the user cares about — "is the item I'm photographing in focus?" — is buried.
- **Interim resolution:** Blur gate is disabled (`QualityGates.checkBlur` always returns `passed=true`). Telemetry log is preserved so we keep collecting variance samples for the redesign. See commit on `main` tagged `fix(quality): disable blur gate pending salience-aware redesign`.
- **Proposed redesign:**
  1. Run the Vision saliency pass (already part of the pipeline, Gate 4) before the blur check.
  2. Crop to the salient bounding box (or a padded version) before computing Laplacian variance.
  3. Re-calibrate against device samples of the cropped subject.
  4. Potentially combine with an on-device CoreML "in-focus / out-of-focus" classifier if Laplacian-on-crop still doesn't separate.
- **Dependencies / interactions:**
  - Pipeline currently runs quality gates sequentially with saliency last; gate order must change.
  - Pairs with Finding #5 (on-device classifier biased toward background) — both are manifestations of "no subject isolation before inference".
- **Acceptance criteria for the redesign:**
  - On Stephen's calibration set (n≥20 mixed sharp/blurry on actual target hardware), the chosen metric separates the two distributions with <10% overlap at the chosen threshold.
  - Threshold is exposed in Settings (pattern already prototyped for blur, never shipped).
  - Pre-existing "Upload Anyway" bypass preserved.

## Ops housekeeping

- Ephemeral admin probe key `dev2-walkthrough-probe` (id=4) revoked at 2026-04-15T19:49:02Z.
- No server-side changes made. No DB mutations other than those driven by Stephen's UI actions (2 locations, 1 bin material, 1 photo, 1 item, 1 class confirm — all against BIN-0003).
- Observational-only walkthrough; no code committed by either agent.
