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

The backend server runs separately on a Raspberry Pi 5. Configure the server URL in the app's Settings tab.

For a TLS-terminated deployment, `mkcert` provides a local CA and trusted certificates; install the root CA on each device. For home-LAN deployments without TLS, the app currently ships with `NSAllowsArbitraryLoads` enabled — see the Security section below for the implications and threat model.

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
