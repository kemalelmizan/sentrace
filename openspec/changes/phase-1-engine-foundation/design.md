# Design

## Context

The repository currently contains the bare `sentrace` Rails Engine skeleton (`lib/sentrace.rb`, `lib/sentrace/engine.rb` with `isolate_namespace Sentrace`, `Sentrace::ApplicationRecord`, `Sentrace::ApplicationController`, a minimal API-only dummy Rails app in `spec/dummy/`, RSpec + FactoryBot, and `rubocop-rails-omakase`). No configuration object, migrations, domain models, generators, or Rake tasks exist yet. See `proposal.md` for motivation and capability scope.

## Goals / Non-Goals

**Goals:**
- Establish clean architectural boundaries between Rails-managed persistence (`app/`) and stateless Ruby domain/configuration primitives (`lib/sentrace/`).
- Deliver the exact PostgreSQL table layouts, data types (`timestamptz`, `smallint`, `bigint`, `jsonb`), uniqueness constraints, and five targeted composite indexes from `SPEC.md` §5.3–5.4.
- Ensure `Sentrace::Dsn` produces DSNs fully compatible with `sentry-ruby`'s `Sentry::DSN` URL resolution both at root domains (`https://KEY@errors.example.com/1`) and path-mounted engines (`https://KEY@app.example.com/sentrace/1`).
- Provide zero-UI installation (`sentrace:install`) and credential operations (`sentrace:projects*`) with digest-only secret storage and constant-time comparison.

**Non-Goals:**
- Implementing HTTP request controllers, Sentry envelope parsing, fingerprinting, or MCP endpoints (deferred to Phases 2–4).
- Adding table partitioning, GIN indexes on `event_data`, or separate tables for tags/breadcrumbs/frames.

## Decisions

### 1. Conventional Rails Engine file layout (`app/` vs `lib/sentrace/`)
- **Decision**: Place ActiveRecord models (`Sentrace::Project`, `Sentrace::ProjectKey`, `Sentrace::Issue`, `Sentrace::Event`) in `app/models/sentrace/`, generators in `lib/generators/sentrace/install/`, Rake tasks in `lib/tasks/sentrace_projects.rake`, and pure Ruby objects (`Sentrace::Configuration`, `Sentrace::Dsn`) in `lib/sentrace/`.
- **Rationale**: Follows standard Rails Engine Zeitwerk conventions so host apps and `spec/dummy` get automatic reloading, while `Sentrace::Configuration` and `Sentrace::Dsn` remain fast, standalone Ruby classes testable without a database connection.
- **Alternatives considered**: Placing models under `lib/sentrace/models/` as sketched in `SPEC.md` §14 — rejected because fighting Rails' default `app/models` autoload path adds boilerplate without improving isolation.

### 2. PostgreSQL schema types, enums, and composite index ordering
- **Decision**: Create four ordered engine migrations under `db/migrate/` (`create_sentrace_projects`, `create_sentrace_project_keys`, `create_sentrace_issues`, `create_sentrace_events`) using explicit PostgreSQL types:
  - `timestamptz` (`t.timestamptz` / `datetime` with PostgreSQL `timestamptz`) for all timestamp columns (`created_at`, `updated_at`, `revoked_at`, `first_seen_at`, `last_seen_at`, `occurred_at`, `received_at`).
  - `smallint` (`limit: 2`) for `sentrace_issues.status` (`unresolved: 0, resolved: 1, ignored: 2`) and `level` (`debug: 10, info: 20, warning: 30, error: 40, fatal: 50`, spaced by 10 in severity order).
  - `jsonb` (`null: false, default: {}`) for `sentrace_events.event_data`, with zero GIN indexes.
  - Explicit descending index sort orders (`order: { last_seen_at: :desc }` and `order: { occurred_at: :desc }`) on the three time-range composite indexes from `SPEC.md` §5.4, avoiding redundant single-column foreign key indexes when a composite index already has `project_id` or `issue_id` as its leading column (`t.references ..., index: false`).
- **Rationale**: Suppressing default single-column `t.references` indexes where `(project_id, ...)` or `(issue_id, ...)` composite indexes already lead with the same column directly satisfies `SPEC.md` §5.4 ("Avoid duplicate indexes created by overlapping composite indexes") and minimizes write amplification on event inserts.
- **Alternatives considered**: Keeping Rails' automatic `index_sentrace_events_on_project_id` alongside `(project_id, event_id)` and `(project_id, occurred_at DESC)` — rejected due to unnecessary index bloat and write overhead.

### 3. Sentry-compatible DSN construction with optional mount prefix
- **Decision**: Implement `Sentrace::Dsn` using Ruby's stdlib `URI` to format `<scheme>://<public_key>@<host>[:port][<mount_path>]/<project_id>` and parse incoming DSN strings into immutable value attributes (`scheme`, `public_key`, `secret_key`, `host`, `port`, `path_prefix`, `project_id`).
- **Rationale**: `sentry-ruby` constructs envelope URLs as `<scheme>://<host>[:port]<path_prefix>/api/<project_id>/envelope/`. Supporting `path_prefix` (e.g., `/sentrace` when mounted in a monolith, or empty when mounted at `/`) guarantees drop-in `sentry-ruby` compatibility in both deployment topologies.
- **Alternatives considered**: Regex-only parsing — rejected because `URI.parse` handles IPv6, ports, and URL encoding edge cases more safely.

### 4. Credential generation, digest storage, and constant-time comparison
- **Decision**: Generate `public_key` via `SecureRandom.hex(16)` (32 lowercase hex chars, fitting `varchar(64)`). When optional secret material is used, compute `OpenSSL::Digest::SHA256.hexdigest(secret)` into `secret_digest` and verify via `ActiveSupport::SecurityUtils.secure_compare`. Expose `Sentrace::ProjectKey.authenticate_public_key(project_id:, public_key:)` scoped to `active: true, revoked_at: nil`.
- **Rationale**: Modern Sentry SDKs (`sentry-ruby`) authenticate envelope ingestion via the DSN `public_key` (`X-Sentry-Auth` / URL userinfo), while `secret_digest` future-proofs legacy/signed callers without ever storing plaintext secrets (`SPEC.md` §5.3, §9.1, §13).
- **Alternatives considered**: `bcrypt` for secret digests — rejected for per-request ingestion authentication because PBKDF/bcrypt CPU cost on high-frequency error spikes creates a self-DoS vector, whereas high-entropy random tokens hashed with SHA-256 + `secure_compare` resist timing attacks in microseconds.

### 5. Thread-safe configuration and per-project user hash secret
- **Decision**: Implement `Sentrace::Configuration` with explicit attribute readers/writers and a `#validate!` check (enforcing positive numeric payload/retention limits and HTTPS on non-loopback `:http` MCP URLs). Derive per-project user-hashing keys in Phase 2 via HMAC-SHA256 seeded from `config.user_hash_secret` (falling back to `Rails.application.secret_key_base`) + project ID so `sentrace_projects` needs no plaintext secret column.
- **Rationale**: Keeps configuration deterministic, resettable in specs (`Sentrace.reset_configuration!`), and compliant with `SPEC.md` §6.2–6.3.
- **Alternatives considered**: `ActiveSupport::Configurable` — rejected because explicit Ruby attributes with validation produce clearer errors and avoid deprecated Rails internals.

## Risks / Trade-offs

- **[PostgreSQL-only column types in migrations]** → Document PostgreSQL `>= 15` requirement clearly and assert PostgreSQL adapter usage in engine setup/CI rather than silently degrading on SQLite.
- **[Duplicate migration copies if host runs generator twice]** → Delegate migration copying inside `sentrace:install` to Rails' idempotent `railties:install:migrations` (`FROM=sentrace`) mechanism and guard route injection by checking `config/routes.rb` for an existing `Sentrace::Engine` mount.
- **[Race conditions when rotating project keys]** → Wrap `Project#rotate_key!` in an ActiveRecord transaction locking the project row so concurrent rotations never leave zero or two unintended active keys.

## Migration Plan

1. Implement configuration and DSN primitives in `lib/sentrace/` with standalone unit specs.
2. Add the four engine migrations in `db/migrate/`, copy/run them against `spec/dummy` PostgreSQL test DB (`bin/rails app:db:prepare`), and add model + schema/index inspection specs.
3. Implement `sentrace:install` generator and `sentrace:projects*` Rake tasks with isolated generator/task specs.
4. Rollback in any host app is standard `bin/rails db:rollback` removing the four `sentrace_*` tables cleanly without touching host tables.
