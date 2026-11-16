# Proposal

## Why

With the Rails Engine configuration, PostgreSQL tables, and project/DSN credentials established in Phase 1, Sentrace now needs its Sentry-compatible ingestion pipeline (`SPEC.md` §4, §5.6, §6, §9.1, §10, §16 Phase 2) so host Rails applications using the official `sentry-ruby` SDK can transmit exceptions and messages into bounded, sanitized, grouped PostgreSQL records.

## What Changes

- Expose `POST /api/:project_id/envelope` on `Sentrace::Engine` with pre-parse body/decompression size enforcement (`413`), DSN public-key authentication (`401` via `X-Sentry-Auth`, `Authorization`, query param, or envelope header), gzip inflation support, and safe error responses (`SPEC.md` §4.2, §9.1, §10, §13).
- Implement `Sentrace::Ingestion::EnvelopeParser` to stream and parse multi-item Sentry envelopes, extracting `event` items while safely discarding `transaction`, `session`, `sessions`, `attachment`, `client_report`, `profile`, `replay_event`, `replay_recording`, and unknown items without database writes (`SPEC.md` §4.3, §5.1).
- Implement `Sentrace::Ingestion::EventNormalizer` and payload truncation rules enforcing configurable bounds on messages (`4 KB`), stack frames (`50`), breadcrumbs (`20`), tags (`32`, keys `64 B`, values `256 B`), and selected contexts (`16` entries, `8 KB` serialized) (`SPEC.md` §4.4–4.5).
- Implement `Sentrace::Ingestion::Sanitizer` to strip request bodies, cookies, authorization headers, session tokens, passwords, payment data, raw IP addresses, raw user emails/names, and arbitrary environment variables, apply recursive `redact_fields` scrubbing, compute per-project HMAC-SHA256 user ID hashes, and run optional host `sanitizer` callables (`SPEC.md` §6.1–6.3).
- Implement `Sentrace::Issues::Fingerprint` and `Sentrace::Issues::Grouper` + `Sentrace::Ingestion::Processor` for deterministic SHA-256 fingerprinting (explicit `fingerprint`, `exception + normalized in-app frames`, or `message` fallback), atomic PostgreSQL `(project_id, fingerprint)` issue upserts, and `(project_id, event_id)` deduplication so retries never double-count (`SPEC.md` §4.6, §5.6).
- Add end-to-end compatibility specs exercising a real `sentry-ruby` (`5.28.1`) client against `Sentrace::Engine` (`SPEC.md` §12.4).

### Out of Scope

- Local `stdio` MCP server, tools, resources, and prompts (`SPEC.md` §16, Phase 3).
- Remote Streamable HTTP MCP endpoint (`/sentrace/mcp`) and multi-environment federation (`SPEC.md` §16, Phase 4).
- Retention batch deletion (`sentrace:retention:cleanup`), internal admin routes, and storage benchmarks (`SPEC.md` §16, Phase 5).
- Legacy Sentry `/api/:project_id/store/` endpoint and all MVP non-goals (`SPEC.md` §1.3, §4.2: transactions, spans, metrics, sessions, replays, attachments, logs, alerting, web UI).

## Capabilities

### New Capabilities

- `sentry-ingestion`: Sentry envelope HTTP ingestion (`POST /api/:project_id/envelope`), pre-parse request/gzip size guards, DSN credential verification, multi-item envelope parsing, event normalization, payload bounds truncation, `(project_id, event_id)` deduplication, and `sentry-ruby` SDK compatibility.
- `privacy-sanitization`: Pre-persistence scrubbing of sensitive HTTP/user/environment fields, recursive configured-key redaction, per-project HMAC user identifier hashing, and custom host sanitizer execution.
- `issue-grouping`: Deterministic, environment-independent SHA-256 fingerprinting and concurrency-safe PostgreSQL issue upsert and occurrence counting.

### Modified Capabilities

<!-- None: existing Phase 1 capabilities remain unchanged at the spec level. -->

## Impact

- **Routes & Controllers**: `config/routes.rb`, `app/controllers/sentrace/ingestion_controller.rb`.
- **Ingestion & Grouping Domain**: `lib/sentrace/ingestion/{envelope_parser,event_normalizer,sanitizer,processor}.rb`, `lib/sentrace/issues/{fingerprint,grouper}.rb`.
- **Tests & Documentation**: Unit specs for parser/normalizer/sanitizer/fingerprint/grouper, request/concurrency/storage specs, real `sentry-ruby` (`5.28.1`) integration specs, and `README.md` SDK compatibility notes.
