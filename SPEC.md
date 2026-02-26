# Bin Brain iOS — Product Specification

> Generated from interview session: 2026-02-25
> Status: v0.1 — pre-implementation

---

## 1. Purpose

Bin Brain is a **personal storage-bin inventory management app** for iOS. The core problem it solves: you have many physical storage bins (workshop parts drawers, shelves, labeled bins) and cannot remember what is in each one. The app lets you photograph a bin's contents, uses AI vision to identify items, and maintains a searchable catalogue so you can instantly find which bin holds any given part.

The iOS app is a thin client to a self-hosted backend stack running on a **Raspberry Pi 5** (always-on, local network). The backend runs Docker Compose with PostgreSQL + pgvector + Ollama, accelerated by a **Hailo AI hat** for vision inference.

---

## 2. Physical System

Each physical storage bin has a printed sticker with:
- A human-readable ID (e.g., `BIN-0001`, sequential format)
- A QR code encoding **only the bin ID string** (e.g., the text `BIN-0001`)

The app uses QR scanning to identify which bin the user is working with, rather than typing the ID manually.

---

## 3. Backend Contract

- **OpenAPI spec**: `openapi.yaml` in project root (source of truth for all API contracts)
- **Deployment**: Raspberry Pi 5 with Hailo AI hat — always-on, local network server
- **Base URL**: user-configurable (default: `https://raspberrypi.local:8000` via mDNS/Bonjour)
- **TLS**: HTTPS via `mkcert` — already configured and working. No `NSAllowsArbitraryLoads` needed.
- **Auth**: none for v1 — trusted local network tool
- **Notable latencies**: AI vision inference timing depends on Hailo acceleration. Ollama is configured to stay warm (loaded once at server startup) — cold start is a non-issue for the iOS app. Only warm inference time is relevant; benchmark on Pi hardware to establish actual UX expectations.

All API communication is over plain HTTP to the local network backend. No TLS required for v1.

---

## 4. Navigation Structure

Three-tab structure:

```
┌─────────────────────────────────────┐
│  [Bins]    [Search]    [Settings]   │
└─────────────────────────────────────┘
```

| Tab | Purpose |
|-----|---------|
| **Bins** | Browse and manage storage bins |
| **Search** | Global semantic search across all items |
| **Settings** | Server configuration and app preferences |

---

## 5. Bins Tab

### 5.1 Bins List Screen

- Sorted by **bin ID** (alphanumeric ascending, e.g., BIN-0001, BIN-0002) — **client-side sort**; the API returns bins ordered by most-recently-updated and the app re-sorts before display
- Each row shows: **bin ID**, **item count**, **last updated** timestamp
- No grouping, no filtering, no thumbnail photos in v1
- Pull-to-refresh fetches updated bin list from `GET /bins`
- Empty state: prompt user to scan their first bin

### 5.2 Bin Detail Screen

**Layout**: Compact primary view — items list with a floating action button (FAB) to trigger camera.

**Items list**:
- Shows all items associated with the bin, each with: name, category, quantity, confidence badge
- Confidence displayed as a visual indicator (color-coded badge or progress chip — not a raw percentage)
- Items sortable by name or by confidence (default: name ascending)
- Inline quantity editing by tapping the quantity value
- Swipe-to-delete on an item removes the bin association (not the item from the catalogue)

**Photos**:
- Photos are tracked by `photo_id` and timestamp — the backend has no file-serving endpoint in v1 (see §15.7)
- **Photo gallery deferred entirely from v1** — no swipe-up sheet, no thumbnail grid, no photo display. A simple photo count badge on the bin detail header is sufficient ("3 photos").
- Post-v1: once `GET /photos/{photo_id}/file` is added to the backend, implement the full photo gallery

**Manual item add**:
- A secondary button or toolbar item opens a manual add sheet (name, category, quantity, notes fields)
- Required for v1

**Missing backend endpoints (backend gaps to track):**
- No `DELETE /bins/{bin_id}/items/{item_id}` — swipe-to-delete a bin-item association is blocked until this exists. **v1 workaround: omit swipe-to-delete; items can only be added, not removed via iOS.**
- No `PATCH /bins/{bin_id}/items/{item_id}` — inline quantity update cannot be persisted. **v1 workaround: quantity shown read-only; editing deferred until endpoint exists.**
- No `DELETE /photos/{photo_id}` — photo deletion is blocked. Moot since photo gallery is cut from v1.

---

## 6. Core Cataloging Workflow

This is the primary user journey and the most critical v1 flow.

```
[Step 1] QR Scan → identify bin
     ↓ (bin auto-created if new)
[Step 2] Photo capture
     ↓
[Step 3] Upload + AI analysis (21–30s, blocked UI with progress)
     ↓
[Step 4] Review AI suggestions with confidence indicators
     ↓ (user edits inline if needed)
[Step 5] Confirm → items written to catalogue and linked to bin
```

### 6.1 QR Scan (Step 1)

- Uses **VisionKit DataScannerViewController** (iOS 16+)
- Camera overlay with a scan-target reticle
- On successful QR decode: extract bin ID string → call `GET /bins/{bin_id}` (or accept 404 as new bin)
- If bin is **new** (404 from backend): ingest call auto-creates it — no intermediate "create bin" step
- Show brief HUD confirmation: "BIN-0042 — 12 items" (existing) or "BIN-0099 — New bin" (new)
- After confirmation, transition to photo capture

### 6.2 Photo Capture (Step 2)

- Uses **DataScannerViewController** (same instance as Step 1) — single camera implementation for the entire app
- `recognizedDataTypes` is set once at init and is immutable — QR recognition runs continuously throughout
- After QR confirmation HUD dismisses, the UI overlay changes to reveal a **shutter button** (QR scanning continues silently in the background but new QR events are gated/ignored until the user manually re-enters scan mode)
- User frames the bin contents and taps the shutter → `capturePhoto()` fires on the active scanner instance
- No library picker, no extra screen — the camera never leaves the viewfinder
- Accepted formats: whatever DataScannerViewController captures (HEIC on modern devices); backend accepts HEIC/HEIF natively
- After capture: transition to upload/analysis screen

### 6.3 Upload & AI Analysis (Step 3)

**Orchestration sequence (two distinct network calls):**
1. `POST /ingest` (multipart, photo + bin_id) → returns `photo_id` immediately (fast, ~ms on LAN)
2. **Compress photo before upload**: resize to max 1920px on longest edge, encode as JPEG quality 0.85 (~300–500KB). Send compressed image, not raw HEIC.
3. `GET /photos/{photo_id}/suggest` → runs Ollama vision inference → returns suggestions (slow, 20-60s on Pi+Hailo — benchmark to establish actual p50)

**UI during step 3:**
- Show **blocked progress screen** immediately after photo capture
- Two-phase messaging: "Uploading photo..." (fast) → "Analysing with AI..." (slow) once ingest returns
- Animated indeterminate progress bar throughout

**Background behaviour:**
- If user backgrounds the app during the suggest call: use `UIApplication.shared.beginBackgroundTask` to request ~30s of extra execution time — sufficient for warm Hailo inference
- If background task expires before response: cancel the request, save a `PendingAnalysis` entry in SwiftData (photo_id + bin_id), notify user with a local notification ("Analysis interrupted — open Bin Brain to retry")
- On notification tap: resume from the pending analysis entry and retry suggest automatically
- **Do not use `URLSessionConfiguration.background`** for the suggest call — background sessions suspend when the socket is idle; AI inference produces no bytes until complete

### 6.4 Suggestion Review (Step 4)

- Display returned item suggestions in a list
- Each suggestion row shows:
  - **Name** (inline editable text field)
  - **Category** (inline editable text field)
  - **Quantity** (pre-filled with AI count estimate, inline editable)
  - **Confidence indicator** (visual badge — color-coded, not a raw number)
  - **Checkbox or toggle** for include/exclude in confirm step
- Users can freely edit name, category, and quantity before confirming
- If AI returns **zero suggestions**: show a guidance screen with tips ("Try better lighting", "Move closer to the contents", "Ensure items are visible") and a retry button (returns to photo capture)
- User can deselect any suggestion before confirming

### 6.5 Confirm (Step 5)

- Tapping "Confirm" calls `POST /items` **once per accepted suggestion** (see §15.1 — `/confirm` endpoint is not used in v1)
- Each call: `POST /items` with `name`, `category`, `quantity`, `confidence`, `bin_id`
- Backend upserts items (fingerprint dedup: `lower(name)|lower(category)`) and associates with the bin in one call
- **Partial failure handling**: calls are made sequentially (not parallel). If any call fails, stop and show an inline error with a "Retry remaining" option. Items successfully committed before the failure are not rolled back (backend upsert is idempotent — re-running is safe).
- Success: return to bin detail view, item list refreshes
- Items that already existed in the catalogue (fingerprint match) are updated in place, not duplicated

---

## 7. Item & Catalogue Model

- **One item entity, multiple bin locations** (warehouse model)
- An item identified in multiple bins shares a single catalogue entry
- The bin-item association tracks **quantity** and **confidence** per bin
- Quantity displayed per-bin (how many are in that specific bin)
- Item deduplication is fingerprint-based: `lower(name)|lower(category)` — editing a name can change its identity

---

## 8. Search Tab

- **Global semantic search** via `GET /search?q=`
- Query is embedded server-side (BAAI/bge-small-en-v1.5) and compared against item embeddings via pgvector
- Results show: item name, category, **all bins containing this item** (e.g., "Found in BIN-0001, BIN-0042")
- Tapping a result navigates to the bin detail for the first/most relevant bin
- Search is debounced (do not fire on every keystroke — wait ~300ms after typing stops)
- Results display with similarity score indicator (converted from distance: `score = 1.0 - (distance / 2.0)` where pgvector cosine distance ranges 0–2; this yields a 0–1 score where 1 = identical)
- Min score: apply the user-configured threshold as `min_score` API parameter (search endpoint accepts score form directly)
- **Note**: The confidence threshold slider (Settings) applies to **search only**. The `/suggest` endpoint has no `min_score` param — the backend filters below 0.5 server-side. Client-side suggestion filtering is not needed.

---

## 9. Settings Tab

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| Server URL | Text field | `https://raspberrypi.local:8000` | Full URL including scheme and port. Default assumes Pi on LAN via mDNS with mkcert HTTPS. |
| Test Connection | Button | — | Calls `GET /health`, shows green ✓ or red ✗ indicator |
| Search Similarity Threshold | Slider | 0.5 | Range 0.0–1.0. Applied as `min_score` to search only. Does not affect AI suggestions (server filters those at 0.5 already). Label: "Minimum similarity (0 = any, 1 = exact)" |
| Pending Uploads | Info + button | — | Shows count of offline-queued photos. "Upload Now" or "Clear Queue" buttons |

Server URL is persisted to `UserDefaults` (not SwiftData — it's configuration, not data).

---

## 10. Offline Photo Queue

- When the user captures a photo but the server is unreachable, the photo is queued in **SwiftData** as a pending upload
- Each pending record stores: compressed JPEG data, target bin ID, queued timestamp, retry count
- **Drain strategy**: standard `URLSession` (default configuration). On app foreground (`sceneWillEnterForeground`) + successful health check, `UploadQueueManager` drains the queue sequentially using async/await. "Upload Now" in Settings triggers the same drain immediately.
- **Do not use `URLSessionConfiguration.background`** for queue uploads — these are small files on a local LAN; background session overhead and OS scheduling delay add complexity with no benefit.
- If an upload attempt fails, increment retry count and leave in queue. After 3 failures, mark as `failed` for user visibility.
- User can view pending count and manually clear the queue from Settings
- Queued items show in the Settings tab with per-item status (pending, uploading, failed)

---

## 11. iOS Architecture

### State Management
- **@Observable ViewModels** + `async/await` — modern vanilla SwiftUI, no third-party architecture framework
- `@Environment` for dependency injection of services (APIClient, QueueManager)
- No Combine, no TCA

### Key Services
| Service | Responsibility |
|---------|---------------|
| `APIClient` | All HTTP calls to the backend. Configured from `UserDefaults` base URL. |
| `UploadQueueManager` | Manages SwiftData-backed offline photo queue. Drains on foreground using standard URLSession. |
| `ServerMonitor` | Lightweight health check on app foreground. Notifies views of server reachability. |

### Networking
- `URLSession` (default configuration) for all API calls — no background URLSession
- **Per-operation timeout profile:**
  - `GET /health`, `GET /bins`, `GET /bins/{id}`, `GET /search`: 10s timeout
  - `POST /ingest` (upload): 30s timeout (small compressed JPEG on LAN)
  - `GET /photos/{id}/suggest`: 120s timeout (AI inference on Pi+Hailo; adjust after benchmarking)
  - `POST /items` (confirm loop): 15s timeout per call
- **Backgrounding during suggest call**: wrap in `UIApplication.shared.beginBackgroundTask` for ~30s of background execution. If task expires, cancel and queue a retry entry in SwiftData.
- No third-party networking library (Alamofire, etc.)

### App Transport Security (ATS)
- HTTPS via `mkcert` is **already configured and working** on the Pi and trusted on iOS devices. No setup required.
- **App default URL**: `https://raspberrypi.local:8000`
- **No `NSAllowsArbitraryLoads`** needed — standard ATS applies, mkcert root CA is already trusted on device

### Camera APIs
- **Single implementation**: `VisionKit.DataScannerViewController` (iOS 16+) handles both QR scanning and still photo capture
- QR mode: `recognizedDataTypes = [.barcode(symbologies: [.qr])]`
- Photo capture: `capturePhoto()` on the active scanner instance — no mode switch, no additional framework
- No PHPickerViewController, no AVFoundation, no photo library picker

### Persistence
- **SwiftData**: offline photo upload queue only
- All bin/item/catalogue data lives on the backend server (no local cache of catalogue data in v1)
- **UserDefaults**: server URL, confidence threshold, and other app preferences

### Error Handling
- Non-blocking **toast/snackbar** at the bottom of the screen for most errors, auto-dismissing after 3–4 seconds
- Inline error states with retry buttons for list-load failures (e.g., bins list fails to fetch)
- "Functional quality": handle server unreachable, upload failure, AI timeout — skip deep edge cases

---

## 12. V1 Required Features (Minimum Viable)

All four of the following must work end-to-end for v1 to be "done enough to use":

1. **Core cataloging**: Scan QR → identify/create bin → capture photo → AI suggestions → review & confirm items
2. **Global semantic search**: Find any item across all bins with bin-location annotation
3. **Manual item management**: Add and edit items within a bin without AI (fallback path)
4. **Settings**: Server URL configuration with connection test

**Explicitly deferred** (post-v1):
- Multi-bin item move/reassign
- Bulk QR code / sticker generation within the app
- iPad-specific split-view layout optimization
- Accessibility (VoiceOver, Dynamic Type) audit
- App Store submission (initially: open-source sideload)

---

## 13. Distribution

- **Open source** — code published to GitHub for anyone to build and sideload
- Personal Xcode signing / free provisioning profile for development use
- No App Store submission planned for v1
- Required entitlements: `background-fetch` (for background task assertions), `remote-notification` (for local notifications on analysis completion)
- **Required privacy strings**: `NSCameraUsageDescription` (DataScannerViewController requires camera access)
- **No `NSAllowsArbitraryLoads`** — HTTPS via `mkcert` means standard ATS applies with no exceptions (see §11 ATS section)

---

## 14. Open Questions / Risks

| Question | Risk | Notes |
|----------|------|-------|
| QR code format on stickers | If sticker format changes, app breaks | Format locked to raw bin ID string |
| Ollama warm inference latency | Unknown until benchmarked on Pi 5 + Hailo | Ollama is kept warm (loaded once at startup) — no cold start concern |
| No auth on backend | Any device on the LAN can write to the catalogue | Acceptable for personal single-user use |
| SwiftData background queue edge cases | Photo loss if queue drain fails silently | Need robust error logging and user visibility of queue state |
| PHPickerViewController vs live camera | PHPicker adds an extra tap vs in-place capture | ~~Revisit~~ — **Resolved below: replace with direct camera** |
| iOS version floor | SwiftData requires iOS 17; DataScanner requires iOS 16 | Floor is iOS 17 |

---

## 15. Pre-Mortem Findings & Mitigations

> Run: 2026-02-25 | Mode: deep | Tigers: 5 | Elephants: 3

---

### 15.1 [HIGH] AI Workflow: Suggest Pipeline ≠ Confirm Endpoint

**Finding:** The spec describes the AI workflow as `ingest → suggest → review → /confirm`, but `POST /photos/{photo_id}/confirm` requires `SelectedGroup.group_key` — a field that only exists in the **detect** pipeline output. The suggest pipeline (`GET /photos/{photo_id}/suggest`) returns `SuggestionItem` which has no `group_key`. These two pipelines are incompatible at the confirm step.

**Root cause:** The OpenAPI spec has two parallel AI pipelines:
- **Suggest pipeline**: `ingest → /suggest` → semantic catalogue matching → no confirm endpoint
- **Detect pipeline**: `ingest → /detect → /groups → /confirm` → bounding-box based → full pipeline, but `/detect` is currently a stub

**Resolution (v1):** The iOS app uses the **suggest pipeline** for AI item identification and commits accepted items via `POST /items` (with `bin_id`, `name`, `category`, `quantity`, `confidence`). This endpoint upserts items using fingerprint dedup and associates them with the bin in a single call. The `/confirm` endpoint is reserved for a future v2 when a real detection model replaces the stub.

**Updated workflow (Step 5):**
```
Confirm → for each accepted suggestion:
  POST /items { name, category, quantity, confidence, bin_id }
  → upserts item, links to bin, handles dedup automatically
```

---

### 15.2 [HIGH] ~~Replace PHPickerViewController with Direct Camera~~ — RESOLVED

**Finding:** PHPickerViewController's default UI is the photo library grid, adding friction to the highest-frequency action.

**Resolution:** Use `DataScannerViewController` for both QR scanning and photo capture. After QR scan, the same camera instance stays open in still-capture mode — user never leaves the viewfinder. Tapping the shutter fires `capturePhoto()` directly. Single framework, zero library-picker friction. PHPickerViewController eliminated entirely.

---

### 15.3 [HIGH] ~~Two-URLSession Design~~ — REVISED to Single Session

**Finding (original):** Background URLSession tasks are OS-managed and cannot be force-triggered from an "Upload Now" button.

**Revised finding (Gemini):** `URLSessionConfiguration.background` is designed for large data transfers — the OS suspends background sessions when a socket is idle. Photo uploads on a local LAN complete in milliseconds, making background session scheduling unnecessary overhead. The AI suggest call has the same idle-socket problem: Ollama inference produces no bytes for 20-60s, so a background session would be killed while waiting for the response.

**Resolution (simplified):** Single `URLSession` with default configuration for everything.
- Queue drains using standard async/await + default URLSession on app foreground
- AI suggest call backgrounding handled via `UIApplication.shared.beginBackgroundTask` (grants ~30s)
- "Upload Now" button just calls the same drain function
- No background URLSession, no session handoff complexity

---

### 15.4 [MEDIUM] Photo Serving: Backend Gap Blocks Gallery Feature

**Finding:** `PhotoRecord.path` is a container-internal filesystem path (e.g., `/data/photos/B-42/abc123.jpg`). No HTTP endpoint serves photo file content in the current OpenAPI spec. The photo gallery swipe-up sheet cannot display images.

**Resolution for v1:** **Photo gallery cut entirely from v1.** Shipping a photo list with no images is UI complexity for zero user value (Gemini's assessment, agreed). Bin detail shows only a photo count badge. The swipe-up sheet is not implemented.

**Backend change needed (post-v1):** Add `GET /photos/{photo_id}/file` to stream photo content. Once this endpoint exists, implement the full gallery with thumbnails and full-size view.

---

### 15.5 [MEDIUM] Distance vs Score: Conversion Layer Required

**Finding:** pgvector cosine distance ranges **0–2** (not 0–1 as originally assumed). `score = 1.0 - distance` can produce negative values for distances > 1. The correct normalisation is `score = 1.0 - (distance / 2.0)`, yielding a 0–1 range.

**Resolution:** Enforce a single rule throughout the iOS codebase:

- **Display always shows score** (`score = 1.0 - (distance / 2.0)`, higher = better match, range 0–1)
- **API calls always send min_score** in score form (the `/search` endpoint accepts score directly)
- **Settings slider label**: "Minimum similarity (0 = any result, 1 = exact match only)"
- The `distance` field from search results is converted to score immediately on decode — never stored or displayed as a raw distance value
- **Confidence threshold applies to search only** — `/suggest` is filtered server-side at 0.5; no client-side suggestion filtering needed

---

### 15.6 [ELEPHANT] Detect Endpoint is a Stub — Confirm is Unusable in v1

The detect endpoint explicitly notes "currently a stub implementation." The `/confirm` endpoint is designed exclusively for the detect pipeline. **The detect → confirm flow does not work in v1.**

This is resolved by the decision in §15.1: use suggest + `POST /items` for v1. The detect pipeline is explicitly deferred to v2 when a real model replaces the stub. The iOS app should not call `/detect` or `/confirm` in v1.

---

### 15.7 [ELEPHANT] No Photo Serving Endpoint

Covered in §15.4. The photo gallery is a **post-v1 feature** contingent on a backend `GET /photos/{photo_id}/file` endpoint being added. This is a backend change, not an iOS change.

---

### 15.8 [ELEPHANT] ~~Server Must Be Awake for App to Function~~ — RESOLVED

**Original concern:** The app fails completely when the server host goes to sleep.

**Resolution:** Backend runs on a **Raspberry Pi 5** — always-on, dedicated server. The Pi does not sleep, does not have a display to close, and does not require user interaction to stay available. This elephant is eliminated by the hardware choice. The app can be treated as having reliable server availability on the home/workshop LAN.
