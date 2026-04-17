# /suggest Progress Heartbeat — Design

**Date:** 2026-04-17
**Author:** ApiDev (server) for Architect review
**Finding:** #18 (walkthrough 2026-04-15) — `/suggest` cold-start up to 149s on qwen3-vl, no progress signal, iOS 15s timeout → NSURLError -1001.
**Status:** Server-side design only; iOS integration to be scheduled separately.

## Goal

Let iOS distinguish "slow but alive" from "frozen" during the long `/suggest` call without re-entering the same queue or breaking the existing response contract.

## Options considered

### Option 1 — Polling endpoint  (CHOSEN)
- New `GET /photos/{photo_id}/suggest/status` returns JSON state snapshot.
- Server keeps an in-process registry (dict + lock) keyed by `photo_id`.
- `/suggest` updates the registry at stage boundaries (`vision` → `embedding_match` → `final`).
- iOS polls every ~5s while the main `/suggest` request is in flight.
- `elapsed_ms` is computed at read time, so even during the long blocking vision call iOS sees a ticking liveness signal.
- Pros: non-breaking, simplest to test, lowest blast radius.
- Cons: in-process registry is per-worker — fine for current single-worker uvicorn; revisit if we scale out. Stage doesn't change DURING the blocking vision call (but `elapsed_ms` does, which is sufficient for liveness).

### Option 2 — Server-Sent Events
- `/suggest` returns `text/event-stream` with progress events.
- Rejected: breaks the existing `/suggest` content-type and iOS call site (requires SSE parser on `URLSession`). Prompt constraint: no breaking changes to `/suggest` without prior iOS migration.

### Option 3 — NDJSON chunked response
- `/suggest` streams `application/x-ndjson`; last line is the final payload.
- Rejected: also breaks `/suggest` content-type. Same constraint applies.

## Chosen contract

```
GET /photos/{photo_id}/suggest/status
```
Requires `X-API-Key` like the rest of `/photos/*`.

### 200 response
```json
{
  "version": "1",
  "photo_id": 42,
  "state": "running",          // "running" | "done" | "failed"
  "stage": "vision",           // "vision" | "embedding_match" | "final" | null
  "started_at": "2026-04-17T12:30:00Z",
  "elapsed_ms": 38421,         // derived at read time
  "error_code": null           // string iff state == "failed"
}
```

### 404 response
Returned when no in-flight or recently-completed job exists for this `photo_id` (TTL 5 min after `state` enters terminal `done` / `failed`, so clients racing between `/suggest` completion and their own poll still see the final state).

### Lifecycle
1. `POST` (really `GET` for `/suggest`, legacy) invokes the route.
2. Route writes `state=running, stage=vision, started_at=now` to the registry **before** `describe_photo` is called.
3. On return: `stage=embedding_match`, then `stage=final, state=done`.
4. On exception: `state=failed, error_code=<slug>` and re-raise.
5. Background lazy sweep: every call into the tracker prunes entries older than 5 min past their terminal timestamp.

## iOS integration shape

1. Bump `/suggest` timeout to ~180s on iOS (per-operation profile).
2. When firing `/suggest`, also start a `Timer` every 5s calling the status endpoint.
3. Treat the status response as liveness + stage display:
   - `state=running, stage=vision` → "Classifying with vision model…" + elapsed time
   - `state=running, stage=embedding_match` → "Matching to catalogue…"
   - `state=done` → ignore (main `/suggest` response is on its way)
   - `state=failed` → surface `error_code` (even before the main request times out)
   - HTTP 404 → treat as "not yet registered" on first poll; on repeated 404 after 15s assume the server restarted and the main request is dead — cancel.
4. Stop polling as soon as the main `/suggest` response arrives (success or failure).

## Testing plan

- Unit: registry transitions + TTL cleanup (pure function on the tracker).
- Integration: monkeypatched `describe_photo` holding for N seconds; in parallel a status poll sees `running/vision`. After completion, status returns `done/final`.
- Failure path: monkeypatched `describe_photo` raising; status returns `failed` with a sensible `error_code`.
- Timing: two status calls ~1s apart observe monotonic `elapsed_ms`.

## What this deliberately does NOT do

- Does not persist status across server restarts (in-memory only; acceptable for the iOS "am I still alive" question).
- Does not expose queue position / concurrency state — /suggest is synchronous today.
- Does not stream progress during the blocking `describe_photo` call. `elapsed_ms` is the only intra-stage signal; the stage itself updates only at boundaries.

## Deferred / follow-ups (not in this change)

- Redis-backed shared registry once we scale to multi-worker.
- Richer stage granularity if/when `describe_photo` can itself emit progress (currently a single blocking HTTP call to Fireworks).
