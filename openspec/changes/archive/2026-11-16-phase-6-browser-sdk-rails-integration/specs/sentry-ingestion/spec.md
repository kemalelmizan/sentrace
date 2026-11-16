# sentry-ingestion Specification

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Event normalization and configurable field truncation
Accepted error events SHALL be normalized into relational attributes (`event_id`, `occurred_at`, `received_at`, `environment`, `release`, `platform`, `level`, `logger`, `culprit`) and bounded `event_data` (`exception` with `lineno`/`colno`, `message`, `request`, `breadcrumbs`, `tags` including safe `X-Request-Id`, `contexts` including `extra`, `user`), truncating fields before persistence.

#### Scenario: Oversized frames, breadcrumbs, tags, and messages are bounded before insert
- **GIVEN** `max_stack_frames = 5`, `max_breadcrumbs = 3`, `max_tags = 2`, and `max_message_bytes = 32`
- **WHEN** an event carrying `12` stack frames, `8` breadcrumbs, `6` tags, and a `100`-byte message is ingested
- **THEN** the stored `event_data` retains at most `5` frames, `3` breadcrumbs, `2` tags, and a valid UTF-8 message truncated to at most `32` bytes

#### Scenario: Preserving integer colno, folding top-level extra, and extracting X-Request-Id header
- **WHEN** an event arrives with stack frame `"colno" => 27`, top-level `"extra" => { "cart_size" => 3 }`, and `"request" => { "headers" => { "X-Request-Id" => "req-abc-123" } }`
- **THEN** the normalized event preserves `"colno" => 27`, stores `"extra" => { "cart_size" => 3 }` inside bounded `contexts`, and sets `tags["request_id"] == "req-abc-123"` while stripping raw request headers
