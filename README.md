# Bin Brain iOS

An iOS app for physical storage bin inventory management. Scan a bin's QR sticker, photograph each item as it goes in, and let AI identify it — building a searchable catalogue so you can instantly find which bin holds any given part.

## Overview

Bin Brain solves the "which bin is that in?" problem for workshops, parts storage, and organized storage systems. Each physical bin gets a printed QR sticker. Scan the sticker, photograph the item you are placing in it, and the AI catalogues it automatically. The photographic subject is a **single item being added to a bin**, not a wide shot of the bin's contents — bin identity comes from the prior QR scan, not the image.

The iOS app is a thin client to a self-hosted backend on a **Raspberry Pi 5** running Docker Compose with PostgreSQL + pgvector + Ollama (optionally accelerated by a Hailo AI hat).

## Features

- **QR scan to identify bins** — DataScannerViewController reads bin stickers (`BIN-0001` format)
- **AI-assisted cataloguing** — photograph each item going into a bin; server-side vision (Ollama `qwen3-vl:4b`) suggests name and category
- **On-device pre-classification** — `VNClassifyImageRequest` runs inside the capture pipeline and uploads top-K labels alongside the photo; a Mode A CoreML integration to surface these as tentative chips before the Ollama response is in design ([`docs/designs/coreml-preclassification-scope.md`](./docs/designs/coreml-preclassification-scope.md))
- **Bounding-box overlay on suggestion review** — server-returned bboxes are rendered over the photo so the user can see which region each suggestion corresponds to before confirming
- **Semantic search** — find any item across all bins using natural language queries (pgvector embeddings)
- **Manual item entry** — add items without AI when preferred
- **Offline photo queue** — photos taken when server is unreachable are queued (SwiftData) and uploaded automatically when connectivity returns

## Architecture

```
iPhone App (SwiftUI)
      │
      │  HTTPS (mkcert, local LAN)
      ▼
Raspberry Pi 5
├── FastAPI backend
├── PostgreSQL + pgvector
├── Ollama (qwen3-vl:4b vision model)
├── BAAI/bge-small-en-v1.5 embeddings
└── Hailo AI hat (optional acceleration)
```

**iOS tech stack:**
- SwiftUI + `@Observable` ViewModels
- SwiftData (offline upload queue)
- URLSession (no third-party networking)
- VisionKit DataScannerViewController (iOS 16+)
- Minimum deployment: iOS 17

**No third-party Swift dependencies.**

## Project Structure

```
binbrain-ios/
├── SPEC.md              # Full product specification
├── openapi.yaml         # Backend API contract (source of truth)
└── Bin Brain/
    ├── Bin Brain.xcodeproj
    └── Bin Brain/       # App source
```

## Getting Started

### Prerequisites

- Xcode 16+
- iOS 17+ device or simulator
- Raspberry Pi 5 running the Bin Brain backend (separate repo)

### Build

1. Open `Bin Brain/Bin Brain.xcodeproj` in Xcode
2. Select your development team under Signing & Capabilities
3. Build and run on a connected device or simulator

### Required Entitlements

- `background-fetch`
- `remote-notification`
- Camera usage (`NSCameraUsageDescription`) for QR scanning and photo capture

### Backend Setup

The backend server runs separately on a Raspberry Pi 5. Configure the server URL in the app's Settings tab.

For a TLS-terminated deployment, `mkcert` provides a local CA and trusted certificates; install the root CA on each device. For home-LAN deployments without TLS, the app currently ships with `NSAllowsArbitraryLoads` enabled — see the Security section below for the implications and threat model.

## API

The backend API is fully specified in [`openapi.yaml`](./openapi.yaml) (symlinked from the sibling `binbrain` repo — the server is the source of truth). Key endpoints used by the iOS client:

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | Connection test |
| `POST /ingest` | Upload photo + device metadata to a bin |
| `GET /photos/{id}/suggest` | AI vision suggestions (items + bboxes) |
| `GET /photos/{id}/suggest/status` | Poll suggestion progress (long Ollama calls) |
| `GET /photos/{id}/detect` | Server-side bbox detection results |
| `POST /photos/{id}/confirm` | Confirm suggestions → create items and associations |
| `POST /photos/{id}/outcomes` | Record per-suggestion accept/reject outcomes |
| `GET /photos/{id}/file` | Download the stored photo (for overlay rendering) |
| `POST /items` | Create/upsert a catalogue item |
| `GET /upc/{upc}` | UPC lookup for barcode-scanned items |
| `GET /bins` · `GET /bins/{id}` | List bins / get bin contents |
| `POST /bins/{id}/add` | Add an existing item to a bin |
| `GET /locations` · `GET /locations/{id}` | Physical location hierarchy |
| `GET /models` · `GET /models/running` · `POST /models/select` | Vision model management (Settings) |
| `POST /settings/image-size` | Configure server-side max image dimension |
| `GET /search?q=` | Semantic search across all bins |

## Security & Threat Model

Bin Brain is designed for **single-user, home-LAN deployment against your own self-hosted backend**. It is not designed for, and has not been hardened for, multi-tenant or internet-exposed use. The expected deployment environment has these properties:

- A small number of trusted devices on a private network
- A backend you control (the Raspberry Pi running Bin Brain server)
- TLS is optional — many home LANs do not run a CA or don't want to manage `mkcert` trust
- Physical device security is the user's responsibility (device passcode, automatic lock)

Under this threat model, some common iOS security postures (certificate pinning, forced HTTPS, App-Store privacy manifest) are intentionally deprioritized. Others — protecting the API key at rest, avoiding credential leakage to misconfigured URLs, not logging PII — still matter.

A full read-only security assessment is kept in the repository at [`SECURITY_ASSESSMENT_130426.md`](./SECURITY_ASSESSMENT_130426.md). Findings are triaged against the threat model above: findings tagged as transport-layer (ATS, cert pinning, cleartext default) are documented but accepted for home-LAN use; findings about credential handling (Keychain, URL-to-key binding, log redaction) and data-at-rest (file protection class) are tracked for remediation.

## Status

iOS client implements the core cataloguing workflow: QR scan → photo capture → on-device image pipeline (quality gates, crop, extract metadata) → upload → AI-assisted suggestion review → confirm → search. See [`SPEC.md`](./SPEC.md) for the full product specification including navigation structure, UI flows, data model, and architectural decisions.
