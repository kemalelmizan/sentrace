# sentry-ingestion Specification

## Purpose
Accepts Sentry-compatible error envelopes over HTTP, authenticates project credentials, enforces request and field size bounds, normalizes error events, discards non-error telemetry without database growth, and deduplicates repeated event deliveries.

## Requirements

### Requirement: Pre-parse body size and gzip decompression limits
The ingestion endpoint (`POST /api/:project_id/envelope`) SHALL enforce `max_envelope_size` on both raw request bodies and `gzip`-compressed streams before JSON parsing, rejecting oversized payloads with HTTP `413` without persisting records or leaking internal stack traces.

#### Scenario: Oversized raw envelope is rejected before parsing
- **GIVEN** `max_envelope_size` configured to `1024` bytes
- **WHEN** a client posts a `2048`-byte envelope to `POST /api/:project_id/envelope`
- **THEN** the endpoint responds with HTTP `413` and creates zero database rows

#### Scenario: Compressed gzip envelope within size limit is accepted
- **GIVEN** a valid `gzip`-compressed Sentry envelope whose decompressed size is below `max_envelope_size`
- **WHEN** a client posts it with `Content-Encoding: gzip`
- **THEN** the endpoint inflates and processes the envelope and responds with HTTP `200`

#### Scenario: Oversized gzip stream is aborted during inflation
- **GIVEN** `max_envelope_size` configured to `2048` bytes
- **WHEN** a client posts a `gzip` payload that inflates past `2048` bytes
- **THEN** inflation halts immediately and the endpoint responds with HTTP `413`

### Requirement: DSN credential validation before payload processing
The ingestion endpoint SHALL authenticate the project DSN public key (and secret when configured on the key) via `X-Sentry-Auth`, `Authorization`, `sentry_key` query parameter, or envelope `dsn` header before processing item payloads, returning HTTP `401` for unknown projects, missing credentials, or revoked keys without exposing database details.

#### Scenario: Valid active project key authenticates ingestion
- **GIVEN** an active project key for project `1`
- **WHEN** `sentry-ruby` sends an envelope with `X-Sentry-Auth` carrying that public key to `/api/1/envelope/`
- **THEN** authentication succeeds and the endpoint responds with HTTP `200` and JSON containing the accepted `id`

#### Scenario: Revoked or mismatched key is rejected with HTTP 401
- **GIVEN** a revoked project key for project `1`
- **WHEN** a client posts an envelope using that revoked key
- **THEN** the endpoint responds with HTTP `401` and creates zero issue or event records

### Requirement: Multi-item envelope parsing and non-error item discarding
The envelope parser SHALL process multiple items in one envelope, persisting `event` error items while discarding `attachment`, `session`, `sessions`, `transaction`, `client_report`, `profile`, `replay_event`, `replay_recording`, and unknown item types without creating database rows, and returning HTTP `400` on malformed envelope framing or invalid JSON.

#### Scenario: Envelope containing error events and unsupported telemetry persists only error events
- **WHEN** an authenticated envelope containing two `event` items, one `transaction` item, one `session` item, and one binary `attachment` item is posted
- **THEN** exactly two `sentrace_events` rows are persisted and the unsupported items create zero database records

#### Scenario: Malformed envelope JSON returns safe HTTP 400 error
- **WHEN** an authenticated request sends truncated or invalid JSON in the envelope header or event item
- **THEN** the endpoint responds with HTTP `400` without exposing internal Ruby stack traces

### Requirement: Event normalization and configurable field truncation
Accepted error events SHALL be normalized into relational attributes (`event_id`, `occurred_at`, `received_at`, `environment`, `release`, `platform`, `level`, `logger`, `culprit`) and bounded `event_data` (`exception`, `message`, `request`, `breadcrumbs`, `tags`, `contexts`, `user`), truncating fields to configured message, frame, breadcrumb, tag, and context limits before persistence.

#### Scenario: Oversized frames, breadcrumbs, tags, and messages are bounded before insert
- **GIVEN** `max_stack_frames = 5`, `max_breadcrumbs = 3`, `max_tags = 2`, and `max_message_bytes = 32`
- **WHEN** an event carrying `12` stack frames, `8` breadcrumbs, `6` tags, and a `100`-byte message is ingested
- **THEN** the stored `event_data` retains at most `5` frames, `3` breadcrumbs, `2` tags, and a valid UTF-8 message truncated to at most `32` bytes

### Requirement: Idempotent event deduplication per project
Repeated ingestion of the same `(project_id, event_id)` MUST NOT create duplicate `sentrace_events` rows and MUST NOT increment the parent issue's `event_count` a second time.

#### Scenario: Duplicate event delivery is safely ignored
- **GIVEN** an event with `event_id` `0123456789abcdef0123456789abcdef` already ingested for project `1`
- **WHEN** the identical event is posted a second time to project `1`
- **THEN** the endpoint responds with HTTP `200`, `sentrace_events` keeps one row for that `event_id`, and `sentrace_issues.event_count` remains `1`

### Requirement: Official sentry-ruby SDK compatibility
An application configured with the official `sentry-ruby` SDK (`~> 5.28`) pointing its DSN at Sentrace SHALL successfully capture exceptions, messages, breadcrumbs, stack traces, and release/environment metadata while gracefully ignoring unsupported SDK items.

#### Scenario: Real sentry-ruby client captures an exception with breadcrumbs and release metadata
- **GIVEN** a `sentry-ruby` client initialized with a Sentrace DSN, `environment = "staging"`, and `release = "v1.2.3"`
- **WHEN** the client records a breadcrumb and calls `Sentry.capture_exception`
- **THEN** Sentrace persists the normalized event, stack frames, breadcrumb, environment, and release under a grouped issue
