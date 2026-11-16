# Tasks

## 1. Engine Configuration & DSN Primitives

- [x] 1.1 Implement `Sentrace::Configuration` (`lib/sentrace/configuration.rb`) and module accessors (`Sentrace.configure`, `Sentrace.configuration`, `Sentrace.reset_configuration!`) with defaults for enablement, retention periods, payload/field limits, redacted field names, custom sanitizer callable, and MCP environment registry, and verify RSpec unit specs cover defaults, overrides, token redaction on `#inspect`, and `#validate!` errors (including rejecting non-HTTPS remote MCP URLs for non-loopback hosts)
- [x] 1.2 Implement `Sentrace::Dsn` (`lib/sentrace/dsn.rb`) to format and parse `<scheme>://<public_key>@<host>[:port][<path_prefix>]/<project_id>` DSNs, and verify unit specs pass for root domains, engine mount prefixes, custom ports, malformed DSNs, and compatibility with `Sentry::DSN.new` from `sentry-ruby`

## 2. PostgreSQL Migrations & Domain Models

- [x] 2.1 Create ordered PostgreSQL engine migrations in `db/migrate/` for `sentrace_projects`, `sentrace_project_keys`, `sentrace_issues`, and `sentrace_events` with `timestamptz` columns, `smallint` enums, `jsonb` `event_data` (`default: {}, null: false`), foreign keys, and the five composite indexes from `SPEC.md` §5.4 (suppressing redundant single-column FK indexes and omitting GIN indexes), and verify `bin/rails app:db:prepare` applies cleanly alongside a schema/index inspection spec
- [x] 2.2 Implement `Sentrace::Project` and `Sentrace::ProjectKey` (`app/models/sentrace/`) with slug/name validations, `SecureRandom.hex(16)` public key generation, SHA-256 `secret_digest` storage, constant-time authentication (`ActiveSupport::SecurityUtils.secure_compare`), and transactional `#rotate_key!`, and verify model specs and FactoryBot factories pass
- [x] 2.3 Implement `Sentrace::Issue` and `Sentrace::Event` (`app/models/sentrace/`) with `status` (`unresolved`, `resolved`, `ignored`) and `level` (`debug`, `info`, `warning`, `error`, `fatal`) `smallint` enums, uniqueness validations/constraints on `(project_id, fingerprint)` and `(project_id, event_id)`, and bounded `event_data` JSONB persistence, and verify model specs and factories pass

## 3. Host Installation Generator & Project Rake Tasks

- [ ] 3.1 Implement `Sentrace::Generators::InstallGenerator` (`lib/generators/sentrace/install/`) with templates to create `config/initializers/sentrace.rb`, mount `Sentrace::Engine` idempotently in `config/routes.rb`, copy engine migrations without duplicates, install project bootstrap instructions, and print the `Sentry.init` snippet, and verify generator specs cover both fresh and repeated runs
- [ ] 3.2 Implement headless Rake tasks (`lib/tasks/sentrace_projects.rake`) for `sentrace:projects`, `sentrace:projects:create[slug]`, and `sentrace:projects:rotate_key[slug]`, and verify task specs cover project listing without secret exposure, project/DSN creation, key rotation, and clean failure on unknown slugs

## 4. Phase 1 Cross-Cutting Verification

- [ ] 4.1 Verify full Phase 1 integration across `spec/dummy` (`bin/rails app:db:prepare`, `rtk bundle exec rspec`, and `rtk bundle exec rubocop` with zero offenses) and update `README.md` installation/CLI usage sections to match delivered generators and Rake tasks

## Workflow follow-up

- Run `rtk openspec validate --all --strict --no-interactive` and archive `phase-1-engine-foundation` once Phase 1 implementation and review are complete.
- Propose `phase-2-sentry-ingestion` next following `SPEC.md` §16.
