# Spec Delta

## MODIFIED Requirements

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
