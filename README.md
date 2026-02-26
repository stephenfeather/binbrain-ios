# Bin Brain iOS

An iOS app for physical storage bin inventory management. Photograph a bin's contents, let AI identify the items, and maintain a searchable catalogue so you can instantly find which bin holds any given part.

## Overview

Bin Brain solves the "which bin is that in?" problem for workshops, parts storage, and organized storage systems. Each physical bin gets a printed QR sticker. Scan the sticker, photograph the contents, and the AI catalogues everything automatically.

The iOS app is a thin client to a self-hosted backend on a **Raspberry Pi 5** running Docker Compose with PostgreSQL + pgvector + Ollama (optionally accelerated by a Hailo AI hat).

## Features

- **QR scan to identify bins** — DataScannerViewController reads bin stickers (`BIN-0001` format)
- **AI-assisted cataloguing** — photograph bin contents, AI vision suggests item names and categories
- **Semantic search** — find any item across all bins using natural language queries (pgvector embeddings)
- **Manual item entry** — add items without AI when preferred
- **Offline photo queue** — photos taken when server is unreachable are queued and uploaded automatically when connectivity returns

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

The backend server runs separately on a Raspberry Pi 5. Configure the server URL in the app's Settings tab (default: `https://raspberrypi.local:8000`).

TLS is handled via `mkcert` — trust the root CA on your device to avoid certificate warnings. No `NSAllowsArbitraryLoads` is required.

## API

The backend API is fully specified in [`openapi.yaml`](./openapi.yaml). Key endpoints:

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | Connection test |
| `POST /ingest` | Upload photo to a bin |
| `GET /photos/{id}/suggest` | AI vision suggestions |
| `POST /items` | Create/upsert a catalogue item |
| `GET /bins` | List all bins |
| `GET /bins/{id}` | Get bin contents |
| `GET /search?q=` | Semantic search |

## Status

**Pre-implementation.** Specification and API contract are complete. iOS domain code has not yet been written — the Xcode project currently contains the default template only.

See [`SPEC.md`](./SPEC.md) for the full product specification including navigation structure, UI flows, data model, and architectural decisions.
