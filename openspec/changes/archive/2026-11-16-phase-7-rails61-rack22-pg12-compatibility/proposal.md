# Proposal

## Why

Enterprise Ruby on Rails applications running long-lived production monoliths on `Rails 6.1.x` (`Rack 2.2.x`), `pg >= 1.4`, and managed `PostgreSQL >= 12` behind CDNs and reverse proxies cannot currently install `sentrace` (`SPEC.md` §1.1, §4, §5, §8, §14) because `sentrace.gemspec` requires `rails >= 7.1` and `pg ~> 1.5`, engine migrations use `ActiveRecord::Migration[7.1]` and Rails 7+ `t.timestamptz`, models use Rails 7.1+ positional `enum ..., validate: true`, and controllers pass Rack 3-only status symbols (`:content_too_large`, `:unprocessable_content`) without `Cache-Control: no-store` headers. Lowering the compatibility floor cleanly to `Rails >= 6.1, < 9.0`, `Rack >= 2.2`, `pg >= 1.4, < 2.0`, and `PostgreSQL >= 12` while adding `Cache-Control: no-store` unlocks enterprise adoption without altering Sentrace's PostgreSQL schema or Rails 7.x/8.x behavior.

## What Changes

- **Gemspec & Ruby 3.3 Boot Compatibility (`sentrace.gemspec`, `lib/sentrace.rb`)**:
  - Relax `rails` dependency to `">= 6.1", "< 9.0"` and `pg` dependency to `">= 1.4", "< 2.0"`, preserving `ruby >= 3.2.0` and `mcp ~> 1.0`.
  - Explicitly `require "logger"` prior to loading ActiveSupport/Rails railties so `Rails 6.1` boots cleanly on `Ruby >= 3.2` / `3.3` with modern `concurrent-ruby`.
- **Engine & Generator Migration Compatibility (`db/migrate/*.rb`, `lib/generators/sentrace/install/install_generator.rb`)**:
  - Update all five engine migrations from `ActiveRecord::Migration[7.1]` to `ActiveRecord::Migration[6.1]`.
  - Replace Rails 7+ `t.timestamptz :<column>` calls with `t.column :<column>, :timestamptz` so `Rails 6.1`, `7.x`, and `8.x` generate identical PostgreSQL `timestamp with time zone` DDL without `NoMethodError`.
- **Cross-Version ActiveRecord Enum Definitions (`app/models/sentrace/`)**:
  - Replace Rails 7.1-only `enum :status, STATUSES, default: :unresolved, validate: true` and `enum :level, LEVELS, prefix: :level, validate: true` on `Sentrace::Issue` and `Sentrace::Event` with cross-version enum macros and explicit validations that behave identically on ActiveRecord `6.1`, `7.x`, and `8.x` (rejecting invalid enum values via ActiveModel validations rather than raising boot-time or setter `ArgumentError`).
- **Rack 2.2 Status Codes & CDN `Cache-Control: no-store` Hardening (`app/controllers/sentrace/**`)**:
  - Replace Rack 3-only `:content_too_large` with numeric `413` in `Sentrace::IngestionController` and `:unprocessable_content` with numeric `422` in `Sentrace::Internal::BaseController` and `Sentrace::Internal::ProjectsController`.
  - Emit `Cache-Control: no-store` on all `IngestionController`, `McpController` (including Rack Streamable HTTP responses), and `Internal::BaseController` responses so upstream CDNs (e.g., Fastly) and reverse proxies never cache envelopes, MCP payloads, or admin responses.
- **PostgreSQL `>= 12` SQL Floor & Multi-Rails Verification (`gemfiles/rails_6_1.gemfile`, `.github/workflows/ci.yml`, `README.md`, `openspec/config.yaml`)**:
  - Enforce PostgreSQL `>= 12` SQL compatibility across all ingestion, grouping, retention, stats, and MCP queries (prohibiting PostgreSQL 15+ `MERGE` or `NULLS NOT DISTINCT`).
  - Add a dedicated `gemfiles/rails_6_1.gemfile` appraisal target (`Rails 6.1` + `Rack 2.2`), update `spec/dummy` and `spec/rails_helper.rb` to run cleanly under both Rails `6.1` and Rails `8.x`, and expand CI matrix coverage across Rails `6.1`/`8.1` and PostgreSQL `12`/`16`.
- **Explicitly Out of Scope (`SPEC.md` §1.3, §5.1–§5.2)**:
  - No tables or rows for transactions, spans, performance metrics, sessions, replays, logs, attachments, external object storage, alerting, or a web UI/dashboard.
  - No changes to column types, uniqueness constraints, composite B-tree indexes, or bounded `sentrace_events.event_data` (`jsonb`) storage discipline; zero GIN indexes.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `engine-configuration`: Support `Rails >= 6.1, < 9.0`, `Rack >= 2.2`, `pg >= 1.4, < 2.0`, and `PostgreSQL >= 12` across engine boot and `sentrace:install`-copied migrations.
- `storage-foundation`: Define engine migrations with `ActiveRecord::Migration[6.1]` and `t.column :<col>, :timestamptz`, preserve PostgreSQL `>= 12` SQL compatibility, and validate `Sentrace::Issue` / `Sentrace::Event` enums identically across ActiveRecord `6.1`, `7.x`, and `8.x`.
- `sentry-ingestion`: Return numeric HTTP `413` for oversized envelopes on Rack `>= 2.2` and set `Cache-Control: no-store` on all ingestion and preflight responses.
- `mcp-federation`: Emit `Cache-Control: no-store` on all `/sentrace/mcp` responses (including error and Streamable HTTP JSON-RPC responses).
- `internal-admin-api`: Return numeric HTTP `422` for validation/parameter errors on Rack `>= 2.2` and emit `Cache-Control: no-store` on all `/sentrace/internal/*` responses.

## Impact

- **Gemspec & Boot (`sentrace.gemspec`, `lib/sentrace.rb`)**: Relaxed `rails` and `pg` version constraints and explicit `logger` stdlib load.
- **Database Migrations (`db/migrate/20261116000001..5_*.rb`)**: `ActiveRecord::Migration[6.1]` + `t.column :<col>, :timestamptz` producing identical PostgreSQL schema and indexes (`SPEC.md` §5.3–§5.4).
- **Models & Controllers (`app/models/sentrace/{application_record,issue,event}.rb`, `app/controllers/sentrace/**`)**: Multi-AR enum helper, numeric `413`/`422` HTTP status codes, and `Cache-Control: no-store` header enforcement.
- **Testing & CI (`gemfiles/rails_6_1.gemfile`, `spec/dummy/**`, `spec/rails_helper.rb`, `.github/workflows/ci.yml`, `README.md`, `openspec/config.yaml`)**: Dual-Rails (`6.1` + `Rack 2.2` and `8.x` + `Rack 3.x`) test execution and PostgreSQL `12` + `16` CI matrix.
