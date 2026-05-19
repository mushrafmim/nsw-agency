# nsw-agency

Officer Government Agency (OGA) portal for the NSW (National Single Window) platform.

This repo contains both halves of OGA:

- [backend/](backend/) — Go service that holds OGA-side application state, talks to the NSW core backend over OAuth2 M2M, and serves the frontend.
- [frontend/](frontend/) — React/Vite SPA used by agency officers (NPQS, FCAU, IRD, CDA) to review trader submissions.

The same codebase is deployed per agency, with branding and identity selected via env vars at build/runtime.

## Quick start

You need the NSW core backend and the Thunder/Asgardeo IdP running first. Both live in the [NSW monorepo](https://github.com/OpenNSW/nsw):

```bash
# In the NSW monorepo
cd nsw && make idp-up && make temporal-up && make backend
```

Then in this repo:

```bash
# Backend
cd backend
cp .env.example .env       # tweak OGA_NSW_* to point at your NSW backend + IdP
go run ./cmd/server

# Frontend (new terminal)
cd frontend
cp .env.example .env       # set VITE_IDP_CLIENT_ID, VITE_API_BASE_URL
pnpm install
pnpm dev
```

## Prerequisites

### 1. NSW backend reachable

OGA calls the NSW core backend's `/api/v1/tasks` endpoint to return review results. Set `OGA_NSW_API_BASE_URL` in [backend/.env](backend/.env) accordingly (default: `http://localhost:8080/api/v1`).

### 2. M2M OAuth2 client

Each OGA instance authenticates to NSW with its own M2M client. For local dev the IdP bootstrap creates a generic `OGA_TO_NSW` client; production deployments use agency-specific clients (`NPQS_TO_NSW`, etc.).

## Architecture

OGA is decoupled from the NSW core monorepo — it communicates over HTTP only:

```
trader-app → nsw-backend → (POST /api/oga/inject) → oga-backend ← oga-app
                  ▲                                       │
                  └────── (POST /api/v1/tasks, OAuth2 M2M)┘
```

- Own database (SQLite or PostgreSQL, per `OGA_DB_*` env vars) — not shared with NSW.
- Templates fetched from [OpenNSW/one-trade-templates](https://github.com/OpenNSW/one-trade-templates) at startup.
- No Temporal integration — OGA is a stateless HTTP microservice.

For details see [backend/docs/architecture.md](backend/docs/architecture.md).

## Releases

Tagging `vX.Y.Z` triggers [.github/workflows/release.yml](.github/workflows/release.yml), which builds and publishes:

- `ghcr.io/opennsw/nsw-agency/oga-backend:X.Y.Z`
- `ghcr.io/opennsw/nsw-agency/oga-app:X.Y.Z`

Image digests are bundled into a `release-digests.json` artifact attached to the GitHub Release.

## History

This repo was extracted from the [NSW monorepo](https://github.com/OpenNSW/nsw) `main` branch in May 2026 via `git-filter-repo`. Git history before that point reflects the monorepo paths (`oga/`, `portals/apps/oga-app/`).
