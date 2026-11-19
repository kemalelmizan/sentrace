# sentry-ingestion Specification

## Purpose
Accepts Sentry-compatible error envelopes over HTTP, authenticates project credentials, enforces request and field size bounds, normalizes error events, discards non-error telemetry without database growth, and deduplicates repeated event deliveries.

## Requirements

### Requirement: Pre-parse body size and gzip decompression limits
The ingestion endpoint (`POST /api/:project_id/envelope`) SHALL enforce `max_envelope_size` on both raw request bodies and `gzip`-compressed streams before JSON parsing, rejecting oversized payloads with numeric HTTP `413` (`Cache-Control: no-store`) on Rack `>= 2.2` without persisting records or leaking internal stack traces.

#### Scenario: Oversized raw envelope is rejected before parsing
- **GIVEN** `max_envelope_size` configured to `1024` bytes
- **WHEN** a client posts a `2048`-byte envelope to `POST /api/:project_id/envelope`
- **THEN** the endpoint responds with HTTP `413` and `Cache-Control: no-store`, and creates zero database rows

#### Scenario: Compressed gzip envelope within size limit is accepted
- **GIVEN** a valid `gzip`-compressed Sentry envelope whose decompressed size is below `max_envelope_size`
- **WHEN** a client posts it with `Content-Encoding: gzip`
- **THEN** the endpoint inflates and processes the envelope and responds with HTTP `200` and `Cache-Control: no-store`

#### Scenario: Oversized gzip stream is aborted during inflation
- **GIVEN** `max_envelope_size` configured to `2048` bytes
- **WHEN** a client posts a `gzip` payload that inflates past `2048` bytes
- **THEN** inflation halts immediately and the endpoint responds with HTTP `413` and `Cache-Control: no-store`

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
The envelope parser SHALL process up to `max_envelope_items` (default `50`) and `max_events_per_envelope` (default `10`) per envelope, rejecting excess items or events with HTTP `413`, enforcing JSON `max_nesting: 64`, persisting `event` error items while discarding non-error telemetry items (`transaction`, `session`, `attachment`, `profile`, `replay_event`) with zero database rows, and returning HTTP `400` on malformed or deeply nested JSON.

#### Scenario: Envelope containing error events and unsupported telemetry persists only error events
- **WHEN** an authenticated envelope containing two `event` items, one `transaction` item, one `session` item, and one binary `attachment` item is posted
- **THEN** exactly two `sentrace_events` rows are persisted and the unsupported items create zero database records

#### Scenario: Envelope exceeding max_events_per_envelope or max_envelope_items returns HTTP 413
- **GIVEN** `max_events_per_envelope` configured to `3`
- **WHEN** an authenticated client posts a single envelope containing `4` error events
- **THEN** the endpoint responds with numeric HTTP `413` (`Cache-Control: no-store`) and avoids unbounded multi-item database amplification

#### Scenario: Malformed or deeply nested envelope JSON returns safe HTTP 400 error
- **WHEN** an authenticated request sends truncated, deeply nested (`> 64` levels), or invalid JSON in the envelope header or event item
- **THEN** the endpoint responds with HTTP `400` without exposing internal Ruby stack traces

### Requirement: Event normalization and configurable field truncation
Accepted error events SHALL be normalized into relational attributes (`event_id`, `occurred_at`, `received_at`, `environment`, `release`, `platform`, `level`, `logger`, `culprit`) and bounded `event_data` (`exception` with `lineno`/`colno` and optional `mechanism`, `message`, `request`, `breadcrumbs`, `tags` including safe `X-Request-Id`, `contexts` including `extra`, `user`), truncating fields before persistence.

#### Scenario: Oversized frames, breadcrumbs, tags, and messages are bounded before insert
- **GIVEN** `max_stack_frames = 5`, `max_breadcrumbs = 3`, `max_tags = 2`, and `max_message_bytes = 32`
- **WHEN** an event carrying `12` stack frames, `8` breadcrumbs, `6` tags, and a `100`-byte message is ingested
- **THEN** the stored `event_data` retains at most `5` frames, `3` breadcrumbs, `2` tags, and a valid UTF-8 message truncated to at most `32` bytes

#### Scenario: Preserving integer colno, folding top-level extra, and extracting X-Request-Id header
- **WHEN** an event arrives with stack frame `"colno" => 27`, top-level `"extra" => { "cart_size" => 3 }`, and `"request" => { "headers" => { "X-Request-Id" => "req-abc-123" } }`
- **THEN** the normalized event preserves `"colno" => 27`, stores `"extra" => { "cart_size" => 3 }` inside bounded `contexts`, and sets `tags["request_id"] == "req-abc-123"` while stripping raw request headers

#### Scenario: Preserving bounded exception mechanism metadata when present
- **WHEN** an event arrives with `"exception" => { "values" => [{ "type" => "RuntimeError", "value" => "boom", "mechanism" => { "type" => "react.error_boundary", "handled" => false } }] }`
- **THEN** the normalized `event_data["exception"]["mechanism"]` retains `{ "type" => "react.error_boundary", "handled" => false }` while events without `mechanism` omit the key

### Requirement: Idempotent event deduplication per project
Repeated ingestion of the same `(project_id, event_id)` MUST NOT create duplicate `sentrace_events` rows and MUST NOT increment the parent issue's `event_count` a second time.

#### Scenario: Duplicate event delivery is safely ignored
- **GIVEN** an event with `event_id` `0123456789abcdef0123456789abcdef` already ingested for project `1`
- **WHEN** the identical event is posted a second time to project `1`
- **THEN** the endpoint responds with HTTP `200`, `sentrace_events` keeps one row for that `event_id`, and `sentrace_issues.event_count` remains `1`

### Requirement: Official sentry-ruby SDK compatibility
An application configured with the official `sentry-ruby` SDK (`~> 5.28`) — either posting HTTP envelopes to a Sentrace DSN or using `Sentrace::SentryTransport` in-process — SHALL capture exceptions, messages, breadcrumbs, stack traces, and release/environment metadata while discarding unsupported SDK items.

#### Scenario: Real sentry-ruby client captures an exception with breadcrumbs and release metadata
- **GIVEN** a `sentry-ruby` client initialized with a Sentrace DSN, `environment = "staging"`, and `release = "v1.2.3"`
- **WHEN** the client records a breadcrumb and calls `Sentry.capture_exception`
- **THEN** Sentrace persists the normalized event, stack frames, breadcrumb, environment, and release under a grouped issue

#### Scenario: Real sentry-ruby client captures an exception in-process via Sentrace::SentryTransport
- **GIVEN** a `sentry-ruby` client initialized with `config.transport.transport_class = Sentrace::SentryTransport`
- **WHEN** the client records a breadcrumb and calls `Sentry.capture_exception`
- **THEN** Sentrace persists the normalized event, stack frames, breadcrumb, and metadata in-process without opening an HTTP socket

### Requirement: Cross-origin browser CORS preflight and response headers
The ingestion endpoint SHALL handle `OPTIONS /api/:project_id/envelope` preflight requests and attach `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, and `Access-Control-Allow-Headers` on `OPTIONS` and `POST` responses when the request `Origin` matches `cors_allowed_origins`, omitting CORS headers for unlisted origins.

#### Scenario: Allowed browser origin receives preflight and POST CORS headers
- **GIVEN** `cors_allowed_origins = ["https://spa.example.com"]`
- **WHEN** a browser sends `OPTIONS /api/1/envelope` and `POST /api/1/envelope` with `Origin: https://spa.example.com`
- **THEN** `OPTIONS` returns HTTP `204` with `Access-Control-Allow-Origin: https://spa.example.com` and `Vary: Origin`, and `POST` includes matching CORS headers

#### Scenario: Unlisted browser origin does not receive CORS allow headers
- **GIVEN** `cors_allowed_origins = ["https://spa.example.com"]`
- **WHEN** a request arrives with `Origin: https://evil.example.com`
- **THEN** the response omits `Access-Control-Allow-Origin`

### Requirement: Browser SDK and sentry-browser wire compatibility
Sentrace SHALL ingest Sentry v7 envelopes sent by both the `sentrace` npm browser SDK and `@sentry/browser`-formatted payloads (`sentry_key` query authentication, `platform: "javascript"`, `colno` frames, `extra`, and `X-Request-Id` correlation).

#### Scenario: Browser envelope with colno stack frames, extra data, and X-Request-Id ingests cleanly
- **GIVEN** an active project key for project `1`
- **WHEN** a browser SDK posts a Sentry v7 envelope authenticated via `?sentry_key=...` with JavaScript frames (`lineno` and `colno`), top-level `extra`, and `request_id`
- **THEN** Sentrace persists the event with `platform == "javascript"`, integer `colno` on frames, sanitized `contexts["extra"]`, and `tags["request_id"]`

### Requirement: Non-cacheable ingestion HTTP responses across Rack 2.2 and 3.x
Every response from `IngestionController` (`POST` and `OPTIONS /api/:project_id/envelope`, across `200`, `202`, `204`, `400`, `401`, `413`, and `500` statuses) SHALL include defensive HTTP security headers (`Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`, and `Referrer-Policy: no-referrer`) and SHALL use Rack `2.2`-compatible numeric status codes where Rack 3 renamed status symbols.

#### Scenario: Ingestion success, preflight, and error responses carry defensive security headers
- **GIVEN** an active project key and `cors_allowed_origins = ["https://spa.example.com"]`
- **WHEN** clients send `OPTIONS /api/1/envelope`, a valid `POST /api/1/envelope`, an unauthorized `POST`, and an oversized `POST`
- **THEN** every response includes `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Content-Security-Policy`, and `Referrer-Policy`, and oversized payloads return numeric HTTP `413` on both Rack `2.2` and Rack `3.x`
