# Spec Delta

## Purpose

Protects sensitive user, credential, and request data by scrubbing forbidden fields, redacting configured secret keys, hashing user identifiers per project, and running custom host sanitizers prior to database persistence.

## ADDED Requirements

### Requirement: Default exclusion of sensitive request, header, and environment fields
Before persisting any event, sanitization SHALL strip request bodies, cookies, authorization headers, session tokens, raw IP addresses, and arbitrary OS/Rack environment variables, retaining only sanitized request URL and HTTP method on the `request` object.

#### Scenario: HTTP request with body, cookies, auth header, IP, and env vars is scrubbed
- **WHEN** an incoming event contains `request` (`url` with sensitive query params, `method`, `data` body, `cookies`, `headers` with `Authorization` and `Cookie`, `env` with `REMOTE_ADDR` and `AWS_SECRET_ACCESS_KEY`)
- **THEN** the persisted `event_data["request"]` retains only sanitized `url` and `method` and excludes bodies, cookies, auth headers, IPs, and environment variables

### Requirement: Recursive field redaction and payment/credential scrubbing
Sanitization SHALL recursively scrub any tag, breadcrumb data, context entry, or message/url query key matching configured `redact_fields` (case-insensitive substring/key match, including `password`, `token`, `authorization`, `cookie`, `credit_card`) as well as card-number patterns, replacing values with `[REDACTED]`.

#### Scenario: Nested context and tag values matching redact_fields are masked
- **WHEN** an event carries `tags: { "api_token" => "secret123", "component" => "auth" }` and nested context `{ "payment" => { "password" => "hunter2", "credit_card" => "4111-1111-1111-1111" } }`
- **THEN** the persisted `event_data` replaces `"secret123"`, `"hunter2"`, and `"4111-1111-1111-1111"` with `"[REDACTED]"` while preserving `"component" => "auth"`

### Requirement: Project-scoped one-way user identifier hashing
Sanitization SHALL strip raw user emails, names, usernames, and IP addresses by default and SHALL replace a present user `id` (or fallback identifier) with a one-way HMAC-SHA256 `id_hash` keyed uniquely per project so user hashes cannot be correlated across projects.

#### Scenario: User context retains only project-specific id_hash
- **WHEN** an event arrives with `user: { "id" => "42", "email" => "alice@example.com", "username" => "alice", "ip_address" => "203.0.113.5" }` for project `1` and project `2`
- **THEN** both persisted events store only `user: { "id_hash" => "<64-hex>" }`, exclude email/username/IP, and produce distinct `id_hash` values across project `1` and project `2`

### Requirement: Custom host sanitizer hook execution
When `Sentrace.configuration.sanitizer` is configured with a callable, Sentrace SHALL invoke it on the normalized, sanitized event payload prior to persistence and enforce field/size bounds on the returned payload.

#### Scenario: Host custom sanitizer transforms event payload before insert
- **GIVEN** a host initializer setting `config.sanitizer = ->(data) { data.merge("tags" => (data["tags"] || {}).merge("scrubbed_by" => "host")) }`
- **WHEN** an error event is ingested
- **THEN** the persisted `event_data["tags"]["scrubbed_by"]` equals `"host"`
