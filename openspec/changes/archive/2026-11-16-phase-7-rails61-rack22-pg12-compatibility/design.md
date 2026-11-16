# Design

## Context

`Sentrace::Engine` (`SPEC.md` §4, §5, §8, §14) was initially authored against `Rails 8.1` (`Rack 3.2`, `pg 1.7`) while keeping Ruby `>= 3.2` compatibility. See `proposal.md` for enterprise stack motivation (`Rails 6.1.7.8`, `Ruby 3.3`, `Rack 2.2.9`, `pg >= 1.4`, `PostgreSQL >= 12`, Fastly CDN + Nginx).

Four concrete framework incompatibilities currently block booting and running Sentrace on `Rails 6.1` + `Rack 2.2`:
1. `Rails 6.1` on `Ruby >= 3.2` / `3.3` with `concurrent-ruby >= 1.3.5` raises `NameError: uninitialized constant ActiveSupport::LoggerThreadSafeLevel::Logger` unless stdlib `logger` is required before `activesupport`.
2. `ActiveRecord::Migration[7.1]` does not exist in Rails `6.1`, and `PostgreSQL::TableDefinition#timestamptz` was only added as a shorthand method in Rails `7.0`.
3. `ActiveRecord::Enum` changed signature across major versions: Rails `6.1` requires keyword arguments (`enum status: STATUSES, _default: :unresolved`, `_prefix: :level`) and raises `ArgumentError` on invalid enum assignment instead of supporting Rails `7.1`'s `validate: true`, whereas Rails `8.0+` removed keyword `enum` in favor of positional `enum :status, STATUSES, default: :unresolved, validate: true`.
4. Rack `2.2` (`Rack::Utils::SYMBOL_TO_STATUS_CODE`) defines `:payload_too_large` (`413`) and `:unprocessable_entity` (`422`), not Rack 3's `:content_too_large` or `:unprocessable_content` (causing `ActionController::Renderers` / `Rack::Utils.status_code` to fall back to `500` or raise `ArgumentError` in Rack `2.2`).

## Goals / Non-Goals

**Goals:**
- Run the exact same engine code, migrations, models, and controllers across `Rails 6.1`, `7.x`, and `8.x` (`Rack 2.2` and `3.x`) against `PostgreSQL >= 12` with zero schema or index drift.
- Ensure every engine HTTP endpoint (`IngestionController`, `McpController`, `Internal::*`) emits `Cache-Control: no-store` so CDNs and reverse proxies never cache responses.
- Verify the full RSpec test suite under both `Rails 6.1` + `Rack 2.2` and `Rails 8.x` + `Rack 3.x`.

**Non-Goals:**
- No new tables, columns, or JSONB GIN indexes; no non-error observability tables.
- No support for Ruby `< 3.2` or non-PostgreSQL databases (`MySQL`, `SQLite`).

## Decisions

### 1. PostgreSQL Schema & Migration Compatibility (`db/migrate/*.rb`)
- **Choice**: Change all five migrations (`20261116000001`..`20261116000005`) from `ActiveRecord::Migration[7.1]` to `ActiveRecord::Migration[6.1]` and replace `t.timestamptz :<col>, ...` with `t.column :<col>, :timestamptz, ...`.
- **Rationale**: `t.column :<col>, :timestamptz` has been supported by ActiveRecord's PostgreSQL adapter since Rails 4/5 and produces the exact same `timestamp with time zone` column DDL, composite DESC B-tree indexes (`index_sentrace_issues_on_project_status_last_seen`, `index_sentrace_events_on_issue_occurred_at`, `index_sentrace_events_on_project_occurred_at`), and uniqueness constraints (`(project_id, fingerprint)`, `(project_id, event_id)`) across Rails `6.1`, `7.x`, and `8.x`.
- **PostgreSQL `>= 12` SQL discipline**: Retain `INSERT ... ON CONFLICT (...) DO UPDATE / DO NOTHING RETURNING id` in `Issues::Grouper`, `DELETE ... WHERE id IN (SELECT ... ORDER BY ... LIMIT ?)` in `Retention::Cleaner`, `DATE_TRUNC` in `LocalBackend` / `StorageStats`, and `->` / `->>` operators in `LocalBackend`, all of which are native since PostgreSQL 9.5–12. Prohibit PG 15+ `MERGE` and `NULLS NOT DISTINCT`.
- **Alternatives considered**:
  - *`t.datetime`*: In Rails `6.1`, `t.datetime` maps to `timestamp without time zone` unless `datetime_type = :timestamptz` is globally overridden on the host's PostgreSQL adapter, which would mutate host application migration behavior. `t.column :<col>, :timestamptz` is explicit and isolated.

### 2. Cross-Version Enum Macro (`Sentrace::ApplicationRecord.sentrace_enum`)
- **Choice**: Implement a small class macro `sentrace_enum(name, values, default: nil, prefix: nil)` in `app/models/sentrace/application_record.rb` (Rails model layer) used by `Sentrace::Issue` (`status`, `level`) and `Sentrace::Event` (`level`):
  - On `ActiveRecord.gem_version >= Gem::Version.new("7.1")`: delegates directly to `enum name, values, **opts, validate: true`.
  - On `ActiveRecord.gem_version >= Gem::Version.new("7.0")` (`7.0.x`): invokes `enum name, values, **opts` (with `default:` / `prefix:`) plus validation wrapper.
  - On `ActiveRecord.gem_version < Gem::Version.new("7.0")` (`6.1.x`): invokes `enum({ name => values, **legacy_opts })` (with `_default:` / `_prefix:`) and overrides `#{name}=` to catch `ArgumentError` for unknown symbols/values, stash the invalid assignment in an instance variable, set the underlying attribute to `nil`, and register an ActiveModel `validate` check that adds `"is not included in the list"` on `errors[name]`.
- **Rationale**: Preserves identical predicate (`unresolved?`, `level_error?`), bang (`resolved!`), scope, type-casting, default (`:unresolved`), and validation semantics (`build(:sentrace_issue, status: :archived).valid? == false` without raising `ArgumentError`) across Rails `6.1`, `7.0`, `7.1`, `7.2`, `8.0`, and `8.1`, while keeping pure domain services in `lib/sentrace/` (`Issues::Grouper`, `Mcp::LocalBackend`) coupled only to `Issue::STATUSES` and `Issue::LEVELS` integer constants.
- **Alternatives considered**:
  - *Removing `ActiveRecord::Enum` completely and hand-rolling methods*: Loses standard ActiveRecord dirty tracking, `_before_type_cast`, scopes, and query map casting.

### 3. Numeric HTTP Statuses & Engine-Wide `Cache-Control: no-store` (`app/controllers/sentrace/`)
- **Choice**:
  - Add `before_action :set_no_store_cache_control` in `Sentrace::ApplicationController` setting `response.set_header("Cache-Control", "no-store")`, and re-assert `response.set_header("Cache-Control", "no-store")` in `Sentrace::McpController#write_rack_response` after copying Rack headers from `MCP::Server::Transports::StreamableHTTPTransport`.
  - Replace `:content_too_large` with `413` in `IngestionController` and `:unprocessable_content` with `422` in `Internal::BaseController` and `Internal::ProjectsController`.
- **Rationale**: Numeric HTTP status codes `413` and `422` are RFC-standard and unambiguous in Rack `2.2`, `3.0`, `3.1`, and `3.2` without triggering Rails 7.1+/Rack 3 deprecation warnings on `:payload_too_large` or `:unprocessable_entity`. Placing `Cache-Control: no-store` on `Sentrace::ApplicationController` guarantees zero CDN/proxy caching across every engine route (`OPTIONS`/`POST` ingestion, `/mcp`, and `/internal/*`) without altering pre-parse `max_envelope_size` stream bounds.

### 4. Multi-Rails Appraisal Gemfile & Dummy App Isolation
- **Choice**: Add `gemfiles/rails_6_1.gemfile` pinning `rails ~> 6.1.7`, `rack ~> 2.2.9`, `pg >= 1.4`, and `rspec-rails ~> 6.1`, guard Rails 7.1+ config keys (`enable_reloading`, `server_timing`, `show_exceptions = :rescuable`) in `spec/dummy/config/environments/{test,development}.rb`, and run engine migrations directly via `ActiveRecord::MigrationContext` in `spec/rails_helper.rb` when `ActiveRecord` is `< 7.1` (bypassing `spec/dummy/db/schema.rb`'s `ActiveRecord::Schema[8.1]` header).
- **Rationale**: Allows local development and CI to execute the identical RSpec suite against both `Gemfile` (Rails `8.1` + Rack `3.2`) and `BUNDLE_GEMFILE=gemfiles/rails_6_1.gemfile` (Rails `6.1` + Rack `2.2`).

## Risks / Trade-offs

- **Rails 6.1 + Ruby 3.3 `Logger` constant load order** -> Requiring `"logger"` at the top of `lib/sentrace.rb` (and `spec/dummy/config/boot.rb` before `rails` loads in specs) guarantees `::Logger` is defined before `ActiveSupport::LoggerThreadSafeLevel` loads.
- **Rack header case variance (`Cache-Control` vs `cache-control`)** -> Using `response.set_header("Cache-Control", "no-store")` (and stripping any lowercase `"cache-control"` from upstream `rack_headers` in `McpController#write_rack_response`) prevents duplicate headers across Rack `2.2` (`HeaderHash`) and Rack `3.x` (lowercase hash keys).
