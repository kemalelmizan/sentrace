# Proposal

## Why

Enterprise Rails + React deployments integrating `sentrace` encounter four operational friction points in day-to-day production use:
1. Substring-based redaction on `"session_id"` and `"token"` falsely masks benign domain foreign keys (`calibration_session_id`, `promotion_calibration_session_id`) and non-secret telemetry flags (`token_present`, `token_expires_in`) with no allowlist override.
2. Self-hosted internal deployments often need specific non-secret user identifiers (`id`, `email`, `username`, `name`, `spoofed_user_id`) retained alongside `user.id_hash`, and `user_id`/`userId` payloads need first-class `id_hash` recognition.
3. `Sentrace::Issues::Fingerprint.normalize_message` only strips word-bounded integers (`/\b\d+\b/`), causing decimal and unit-suffixed latency/metric messages (`"Slow Lark API response: 3.45s for user 812"`, `"250ms"`, `"12.5%"`, `"10MB"`) to fragment into hundreds of separate issues.
4. Ephemeral container CI/CD pipelines across `staging`, `pre-prod`, and `production` need zero-SSH, idempotent credential bootstrapping from environment variables plus clear reverse-proxy (`X-Forwarded-Proto`) and OWASP ModSecurity CRS (`920420`, `930120`, `941xxx`, `942xxx`) guidance.

## What Changes

- **Precision Session Redaction & `allow_fields` Override (Ruby & Browser SDK)**:
  - Add `config.allow_fields` (default `[]`) on `Sentrace::Configuration` and `allowFields?: string[]` on JS `SentraceOptions` to case-insensitively exempt listed field names from key-name redaction across URLs, tags, breadcrumbs, and contexts while still scrubbing Bearer tokens and Luhn-valid payment card numbers inside string values.
  - Refine default session redaction in `Sentrace::Ingestion::Sanitizer` and `packages/sentrace/src/dsn.ts` (`scrubUrl`) so auth session keys (`session`, `session_id`, `_session_id`, `rack.session`, `_<app>_session`, `*_session_token`) remain redacted by default without redacting domain foreign keys like `calibration_session_id` or `promotion_calibration_session_id`.
- **Opt-In User Field Retention & `user_id`/`userId` Hashing**:
  - Keep `id_hash`-only user persistence as the default (`config.retain_user_fields = []`).
  - Recognize `user_id` and `userId` (in addition to `id`, `username`, and `email`) when computing project-scoped HMAC-SHA256 `user.id_hash`.
  - Add `config.retain_user_fields` (default `[]`) to retain configured scalar fields from `raw_user` alongside `id_hash` in `event_data["user"]` (truncated to `<= 256` UTF-8 bytes per field, rejecting credential/session/IP keys, and scrubbing Bearer/Luhn patterns).
- **Float & Unit-Suffix Message Fingerprinting**:
  - Normalize floating-point numbers and numeric+unit tokens (`3.45s`, `250ms`, `12.5%`, `10MB`, `3.45`) in `Sentrace::Issues::Fingerprint.normalize_message` prior to integer normalization so duration and metric warning messages group deterministically into a single issue.
- **Idempotent CI/CD Credential Bootstrap & Proxy/WAF Documentation**:
  - Add `Sentrace::Project.ensure!(slug:, name: nil, public_key: nil)` and `Sentrace::McpToken.ensure!(name: "default", token: nil)` for idempotent boot-time credential seeding without rotating existing credentials or storing plaintext MCP tokens.
  - Add built-in `bin/rails sentrace:bootstrap` and update the `sentrace:setup` generator template to read optional `SENTRACE_PROJECT_SLUG`, `SENTRACE_PROJECT_PUBLIC_KEY`, `SENTRACE_MCP_TOKEN_NAME`, and `SENTRACE_MCP_TOKEN` environment variables idempotently.
  - Document TLS-terminating reverse-proxy `X-Forwarded-Proto: https` requirements for `/sentrace/mcp` and reference OWASP ModSecurity CRS exclusions (`920420`, `930120`, `941xxx`, `942xxx`) for `/sentrace/api/` and `/sentrace/mcp` in `README.md`.

### Out of Scope (`SPEC.md` Section 4 Non-Goals)
- No tables, columns, or rows for transactions, spans, performance metrics, sessions, replays, logs, or attachments.
- No GIN indexes on `sentrace_events.event_data` and no schema migrations (`db/migrate/` unchanged).
- No web dashboard UI or plaintext storage of MCP bearer tokens.

## Capabilities

### New Capabilities
<!-- None; all changes extend existing capabilities cleanly. -->

### Modified Capabilities
- `engine-configuration`: Add `allow_fields` and `retain_user_fields` configuration settings with type validation, and update `sentrace:install`'s `sentrace:setup` task template to support idempotent environment-variable bootstrapping.
- `privacy-sanitization`: Exempt `allow_fields` from key-name redaction, narrow default session key matching to auth session identifiers (preserving `*_session_id` domain foreign keys), hash `user_id`/`userId` into `id_hash`, and support bounded opt-in `retain_user_fields`.
- `issue-grouping`: Normalize floating-point numbers and numeric+unit tokens (`3.45s`, `250ms`, `12.5%`, `10MB`) in message-based fingerprinting.
- `project-management`: Add `Sentrace::Project.ensure!(slug:, name: nil, public_key: nil)` and built-in `bin/rails sentrace:bootstrap` task for idempotent CI/CD project and DSN key provisioning.
- `mcp-federation`: Add `Sentrace::McpToken.ensure!(name:, token: nil)` for idempotent digest-only MCP bearer token seeding from environment secrets.
- `browser-sdk`: Add `allowFields?: string[]` to `SentraceOptions` and refine client URL query scrubbing so `*_session_id` domain foreign keys are preserved while auth session parameters remain redacted.

## Impact

- **Ruby Engine**: `lib/sentrace/configuration.rb`, `lib/sentrace/ingestion/sanitizer.rb`, `lib/sentrace/issues/fingerprint.rb`, `app/models/sentrace/project.rb`, `app/models/sentrace/mcp_token.rb`, `lib/sentrace/bootstrapper.rb`, `lib/tasks/sentrace_bootstrap.rake`, `lib/generators/sentrace/install/templates/sentrace_setup.rake.tt`, `lib/generators/sentrace/install/templates/initializer.rb.tt`.
- **Browser SDK**: `packages/sentrace/src/{types,dsn,client,browser,rails}.ts` and compiled `dist/` + `app/assets/javascripts/` bundles.
- **Documentation & Tests**: `README.md`, RSpec model/lib/generator/task specs, and `packages/sentrace/test/*.test.mjs`.
