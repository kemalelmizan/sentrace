# Design

## Context

See `proposal.md` for motivation and scope. Phase 8 refines sanitization precision, opt-in internal user context retention, float/metric message fingerprinting, and non-interactive CI/CD credential bootstrap across `Sentrace::Engine` and `packages/sentrace` without altering the PostgreSQL schema or adding any indexes.

## Goals / Non-Goals

**Goals:**
- Eliminate false-positive redaction on domain foreign keys (`calibration_session_id`, `promotion_calibration_session_id`) and explicit `allow_fields` / `allowFields` telemetry keys (`token_present`, `token_expires_in`) across Ruby and JavaScript while keeping auth session and credential keys redacted by default.
- Support project-scoped `id_hash` computation from `user_id` and `userId`, plus bounded opt-in `retain_user_fields` for self-hosted internal apps.
- Group decimal and unit-suffixed latency/metric messages (`3.45s`, `250ms`, `12.5%`, `10MB`) deterministically into a single issue fingerprint.
- Enable zero-SSH, idempotent CI/CD credential provisioning via `Project.ensure!`, `McpToken.ensure!`, `sentrace:bootstrap`, and `sentrace:setup`, plus document reverse-proxy `X-Forwarded-Proto` and OWASP ModSecurity CRS exclusions.

**Non-Goals:**
- No DDL migrations, new tables, columns, or GIN indexes on `sentrace_events.event_data`.
- Never persist plaintext MCP bearer tokens or echo CI-supplied `SENTRACE_MCP_TOKEN` secrets to stdout logs.

## Decisions

### 1. Precision Auth-Session Matching + `allow_fields` Precedence (`lib/sentrace/ingestion/sanitizer.rb` & `packages/sentrace/src/dsn.ts`)
- **Decision**:
  - Evaluate `allow_fields` / `allowFields` first via case-insensitive exact key membership (`downcased_key` in `allow_set`). Even when a key is allowed, its string value still passes through `Sanitizer#scrub_text` (`Bearer <token>` and Luhn PAN scrubbing), and top-level `FORBIDDEN_CONTEXT_KEYS` (`env`, `rack_env`, `headers`, `cookies`, `session`) remain excluded.
  - Remove `"session_id"` (and `"session"` in JS) from substring redaction lists. Instead, match auth session keys explicitly via `AUTH_SESSION_EXACT_KEYS` (`session`, `session_id`, `_session_id`, `rack.session`, `phpsessid`, `jsessionid`, `connect.sid`) and `AUTH_SESSION_KEY_REGEX` (`/\A_(?:[a-z0-9_]+_)?session\z|(?:^|[_.-])session[_.-]?token\z/`).
- **Rationale**: Substring matching `.include?("session_id")` treats every Rails `belongs_to :*_session` foreign key as a session cookie. Explicit auth-session matching redacts `_myapp_session`, `session_id`, `_session_id`, `rack.session`, and `user_session_token` while leaving `calibration_session_id` untouched out of the box.

### 2. Bounded Opt-In `retain_user_fields` (`lib/sentrace/ingestion/sanitizer.rb`)
- **Decision**:
  - Extend `sanitize_user` identifier lookup order to `id` -> `user_id` -> `userId` -> `username` -> `email` (string or symbol keys) for HMAC-SHA256 `id_hash`.
  - Keep `config.retain_user_fields = []` by default. When non-empty, iterate up to `16` unique configured field names, rejecting `"id_hash"`, `FORBIDDEN_CONTEXT_KEYS`, auth-session keys, and credential/IP patterns (`password`, `passwd`, `secret`, `token`, `authorization`, `cookie`, `credit_card`, `card_number`, `cvv`, `cvc`, `api_key`, `apikey`, `ip_address`, `remote_addr`, `remote_ip`, `client_ip`).
  - Retain only scalar values (`String`, `Numeric`, `true`, `false`), scrubbing Bearer/Luhn patterns and truncating strings to `<= 256` UTF-8 bytes (`EventNormalizer.truncate_utf8_bytes`), and re-enforce the same bounds in `enforce_post_sanitizer_bounds`.
- **Rationale**: Preserves strict bounded `jsonb` storage (`<= ~4 KB` worst-case user object) and prevents accidental credential or IP retention even if `retain_user_fields` is misconfigured.

### 3. Canonical Numeric & Unit-Suffix Normalization (`lib/sentrace/issues/fingerprint.rb`)
- **Decision**:
  - After timestamp, UUID, object-address, and long-hex normalization in `Fingerprint.normalize_message`, apply:
    1. `NUMERIC_WITH_UNIT_REGEX` matching signed/unsigned integers or decimals followed by `%` or standard duration/size/rate units (`ns`, `us`, `µs`, `μs`, `ms`, `msecs`, `s`, `secs`, `seconds`, `m`, `mins`, `minutes`, `h`, `hrs`, `hours`, `d`, `days`, `b`, `bytes`, `kb`, `kib`, `mb`, `mib`, `gb`, `gib`, `tb`, `tib`, `pb`, `pib`, `hz`, `khz`, `mhz`, `ghz`, `pct`, `rps`, `qps`, `px`) -> `"<num>"`.
    2. `FLOAT_REGEX` (`/(?<![A-Za-z0-9_.])-?\d+\.\d+(?!\.\d)\b/`) -> `"<num>"`.
    3. `INTEGER_REGEX` (`/\b\d+\b/`) -> `"<num>"`.
- **Rationale**: Using a single `"<num>"` placeholder across numeric+unit, float, and integer tokens ensures `"Slow Lark API response: 3.45s"`, `"Slow Lark API response: 4s"`, and `"Slow Lark API response: 250ms"` collapse into `"Slow Lark API response: <num>"`, while `(?<![A-Za-z0-9_.])` avoids corrupting identifiers like `S3`, `v2`, `sha256`, or `oauth2`.

### 4. Concurrency-Safe `Project.ensure!`, `McpToken.ensure!`, and `Sentrace::Bootstrapper` (`app/models/sentrace/`, `lib/sentrace/bootstrapper.rb`)
- **Decision**:
  - Domain persistence lives on `Sentrace::Project.ensure!(slug:, name: nil, public_key: nil)` and `Sentrace::McpToken.ensure!(name: "default", token: nil)` in `app/models/sentrace/`, while CLI/env orchestration lives in `Sentrace::Bootstrapper` (`lib/sentrace/bootstrapper.rb`) invoked by `lib/tasks/sentrace_bootstrap.rake` (`sentrace:bootstrap`) and generated `sentrace:setup`.
  - `Project.ensure!` validates `public_key` against `/\A[A-Za-z0-9_-]{16,64}\z/` when given, rejects keys owned by another project or previously revoked, finds-or-creates the project (retrying on concurrent `ActiveRecord::RecordNotUnique`), and ensures an active `ProjectKey` with `public_key` exists under `project.with_lock` without revoking in-flight active keys or duplicating rows.
  - `McpToken.ensure!` validates `raw_token` against `/\Asnt_mcp_[A-Za-z0-9_-]{24,256}\z/` when given, computes `digest_token(raw_token)`, rejects revoked digests, and idempotently finds-or-creates the active `McpToken` storing only `token_prefix` and `token_digest`, returning `[record, newly_generated_plaintext_or_nil]`.

## Risks / Trade-offs

- **[Risk] Changing `<int>` to `<num>` alters fingerprints for existing message-only issues containing numbers** → Acceptable and expected when upgrading message normalization; frame-based exception fingerprints (the vast majority of issues) do not use `normalize_message` and remain completely unchanged.
- **[Risk] CI/CD logs leaking secrets during `sentrace:bootstrap`** → `Bootstrapper` never prints caller-supplied `SENTRACE_MCP_TOKEN` values to stdout (printing only `record.token_prefix`); plaintext is printed once only when `McpToken.ensure!` freshly generates a random token (`token: nil`).
