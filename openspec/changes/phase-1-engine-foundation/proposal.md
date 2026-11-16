# Proposal

## Why

Sentrace requires a rock-solid Rails Engine foundation before envelope ingestion or MCP interfaces can be built (`SPEC.md` §16, Phase 1). Host Rails applications need a clean installation path, isolated configuration, engine-owned PostgreSQL tables with strict storage and uniqueness guarantees, and headless project/DSN credential lifecycle management.

## What Changes

- Introduce `Sentrace::Configuration` (`Sentrace.configure`, `Sentrace.configuration`, `Sentrace.reset_configuration!`) with defaults and validation for enablement, event/orphan retention periods, payload and field bounds (`SPEC.md` §4.5), sensitive field redaction lists and custom sanitizer hooks (`SPEC.md` §6.3), and federated MCP environment definitions (`SPEC.md` §7.3).
- Add the `sentrace:install` Rails generator (`bin/rails generate sentrace:install`) that creates `config/initializers/sentrace.rb`, mounts `Sentrace::Engine` in host routes, copies engine-owned migrations, provides project/DSN bootstrap tasks, and prints a ready-to-use `sentry-ruby` configuration snippet (`SPEC.md` §8.2).
- Add engine-owned PostgreSQL migrations (`db/migrate/`) defining `sentrace_projects`, `sentrace_project_keys`, `sentrace_issues`, and `sentrace_events` with `timestamptz` timestamps, `smallint` status/level enums, bounded `jsonb` `event_data`, foreign keys, uniqueness constraints, and the five targeted indexes specified in `SPEC.md` §5.3–5.4.
- Implement isolated ActiveRecord models under `app/models/sentrace/` (`Project`, `ProjectKey`, `Issue`, `Event`) enforcing schema invariants, status/level enums, digest-only secret storage, and constant-time credential verification (`SPEC.md` §5.3, §9.1, §13).
- Implement `Sentrace::Dsn` for formatting and parsing Sentry-compatible DSNs (`https://PUBLIC_KEY@host/PROJECT_ID`) alongside administrative Rake tasks (`sentrace:projects`, `sentrace:projects:create[slug]`, `sentrace:projects:rotate_key[slug]`) that operate without any web dashboard (`SPEC.md` §4.1, §8.3).

### Out of Scope

- Sentry envelope HTTP endpoint (`POST /api/:project_id/envelope`), envelope parsing, event normalization, payload truncation/sanitization execution, and deterministic issue fingerprinting/grouping (`SPEC.md` §16, Phase 2).
- Local `stdio` MCP server, tools, resources, and investigation prompts (`SPEC.md` §16, Phase 3).
- Remote Streamable HTTP MCP endpoint (`/sentrace/mcp`), bearer-token MCP authentication, and multi-environment federation router (`SPEC.md` §16, Phase 4).
- Batch retention cleanup execution (`sentrace:retention:cleanup`) and repeatable PostgreSQL storage benchmarks (`SPEC.md` §16, Phase 5).
- All MVP non-goals (`SPEC.md` §1.3): transactions, spans, metrics, sessions, replays, logs, attachments, external object storage, alerting, web UI/dashboard, and host user authentication models.

## Capabilities

### New Capabilities

- `engine-configuration`: Isolated Rails Engine configuration (`Sentrace.configure`) for runtime toggles, retention, payload limits, privacy redaction, and MCP environment definitions, plus the `sentrace:install` host-application generator.
- `storage-foundation`: Engine-owned PostgreSQL schema, targeted indexing strategy, and isolated ActiveRecord models (`Sentrace::Project`, `Sentrace::ProjectKey`, `Sentrace::Issue`, `Sentrace::Event`) with bounded `jsonb` storage and uniqueness guarantees.
- `project-management`: Headless project lifecycle, Sentry-compatible DSN construction and parsing, digest-backed credential management with constant-time verification, key rotation/revocation, and `sentrace:projects*` Rake tasks.

### Modified Capabilities

<!-- None: greenfield repository with no pre-existing capabilities in openspec/specs/. -->

## Impact

- **Engine & Domain Code**: `lib/sentrace.rb`, `lib/sentrace/engine.rb`, `lib/sentrace/configuration.rb`, `lib/sentrace/dsn.rb`.
- **Generators & Tasks**: `lib/generators/sentrace/install/install_generator.rb` (plus templates), `lib/tasks/sentrace_projects.rake`.
- **Persistence & Models**: `db/migrate/*_create_sentrace_*.rb`, `app/models/sentrace/{project,project_key,issue,event}.rb`.
- **Test Suite**: `spec/dummy/` migrations/config integration, FactoryBot factories under `spec/factories/`, and RSpec unit/model/generator/task specs under `spec/`.
- **Database Requirements**: PostgreSQL `>= 15` (`jsonb`, `timestamptz`, `bigint`, `smallint`, composite unique/btree indexes).
