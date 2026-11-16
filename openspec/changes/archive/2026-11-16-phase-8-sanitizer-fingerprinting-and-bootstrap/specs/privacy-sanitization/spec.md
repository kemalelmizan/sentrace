# privacy-sanitization Specification (Delta)

## MODIFIED Requirements

### Requirement: Recursive field redaction and payment/credential scrubbing
Sanitization SHALL recursively scrub tags, breadcrumb data, contexts, and URL query keys matching `redact_fields`, default credential/IP patterns, or auth session keys (`session`, `session_id`, `_session_id`, `rack.session`, `_<app>_session`, `*_session_token`) unless exempted case-insensitively by `allow_fields`, MUST preserve non-auth `*_session_id` domain keys, and SHALL always mask Bearer and Luhn card patterns.

#### Scenario: Nested context and tag values matching redact_fields are masked
- **WHEN** an event carries `tags: { "api_token" => "secret123", "component" => "auth" }` and nested context `{ "payment" => { "password" => "hunter2", "credit_card" => "4111-1111-1111-1111" } }`
- **THEN** the persisted `event_data` replaces `"secret123"`, `"hunter2"`, and `"4111-1111-1111-1111"` with `"[REDACTED]"` while preserving `"component" => "auth"`

#### Scenario: Auth session keys are redacted while domain foreign keys remain intact
- **WHEN** an event contains query parameters and context fields `session_id=sess_1`, `_myapp_session=cookie_2`, `user_session_token=tok_3`, `calibration_session_id=42`, and `promotion_calibration_session_id=99`
- **THEN** `session_id`, `_myapp_session`, and `user_session_token` are replaced with `"[REDACTED]"` while `calibration_session_id` (`42`) and `promotion_calibration_session_id` (`99`) are preserved unredacted

#### Scenario: Keys listed in allow_fields bypass key-name redaction while values remain pattern-scrubbed
- **GIVEN** `config.allow_fields = %w[token_present token_expires_in]`
- **WHEN** an event arrives with `tags: { "token_present" => "true", "access_token" => "secret_abc" }`, URL query `?TOKEN_EXPIRES_IN=3600&api_token=xyz`, and context `{ "auth" => { "token_present" => "Bearer leaked_jwt" } }`
- **THEN** `token_present` (`"true"`) and `TOKEN_EXPIRES_IN` (`"3600"`) are preserved, `access_token` and `api_token` are `"[REDACTED]"`, and `"Bearer leaked_jwt"` is still scrubbed to `"Bearer [REDACTED]"`

### Requirement: Project-scoped one-way user identifier hashing
Sanitization SHALL compute a project-scoped HMAC-SHA256 `id_hash` from `id`, `user_id`, `userId`, `username`, or `email`, SHALL strip all raw user attributes by default (`retain_user_fields = []`), and when `retain_user_fields` is configured SHALL retain only listed non-secret scalar fields truncated to `<= 256` UTF-8 bytes alongside `id_hash` while rejecting credential/IP keys and scrubbing Bearer/Luhn patterns.

#### Scenario: User context retains only project-specific id_hash
- **WHEN** an event arrives with `user: { "id" => "42", "email" => "alice@example.com", "username" => "alice", "ip_address" => "203.0.113.5" }` for project `1` and project `2`
- **THEN** both persisted events store only `user: { "id_hash" => "<64-hex>" }`, exclude email/username/IP, and produce distinct `id_hash` values across project `1` and project `2`

#### Scenario: Computing id_hash from user_id and userId keys
- **WHEN** events arrive with `user: { "user_id" => 108 }` or `user: { "userId" => "108" }` and default `retain_user_fields = []`
- **THEN** both events compute the identical project-scoped 64-character `id_hash` as `user: { "id" => "108" }` and omit raw keys

#### Scenario: Retaining configured non-secret scalar user fields with byte and pattern bounds
- **GIVEN** `config.retain_user_fields = %w[id email name spoofed_user_id api_token ip_address]`
- **WHEN** an event arrives with `user: { "id" => 42, "email" => "alice@internal.corp", "name" => "A" * 400, "spoofed_user_id" => "Bearer secret_jwt", "api_token" => "tok_1", "ip_address" => "10.0.0.1", "roles" => ["admin"] }`
- **THEN** `event_data["user"]` contains `id_hash`, `id` (`42`), `email` (`"alice@internal.corp"`), `name` truncated to `256` UTF-8 bytes, and `spoofed_user_id` (`"Bearer [REDACTED]"`), while excluding `api_token`, `ip_address`, and non-scalar `roles`
