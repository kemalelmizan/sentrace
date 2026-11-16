# Proposal

## Why

Phases 1–4 delivered Sentrace's isolated PostgreSQL Rails Engine, Sentry v7 envelope ingestion with privacy sanitization, deterministic issue grouping, local `stdio` MCP server, and authenticated cross-environment Streamable HTTP federation. To complete the MVP defined in `SPEC.md` §5.7, §5.8, §8.1, §8.3, §11, §11.1, §13, §14, §15, and §16 (Phase 5), Sentrace needs bounded batch event retention cleanup, PostgreSQL-derived storage observability, internal administrative JSON routes, a repeatable PostgreSQL storage and latency benchmark, explicit security/performance verification specs, and complete release documentation.

## What Changes

- **Batch Event & Orphan Issue Retention (`SPEC.md` §5.7 & §8.3)**:
  - Add `Sentrace::Retention::Cleaner` (`lib/sentrace/retention/cleaner.rb`) to delete expired `sentrace_events` (`occurred_at < Time.current - config.retention_period`) in bounded batches (`config.retention_batch_size`, default `1000`) without immediately deleting parent issues, and prune zero-event `sentrace_issues` older than `config.orphan_issue_retention_period`.
  - Expose retention through `Sentrace::RetentionCleanupJob` (`ActiveJob::Base`, requiring no Redis or specific queue adapter) and `bin/rails sentrace:retention:cleanup`.
- **PostgreSQL Storage Observability & Repeatable Benchmark (`SPEC.md` §5.8, §11, §11.1)**:
  - Add `Sentrace::StorageStats` (`lib/sentrace/storage_stats.rb`) and `bin/rails sentrace:stats` computing total events, total issues, daily event counts, PostgreSQL table/index storage bytes (`pg_table_size`, `pg_indexes_size`, `pg_total_relation_size`), oldest retained event timestamp, and events removed by retention using PostgreSQL catalog metadata and aggregate queries without persisting individual metric rows.
  - Add `Sentrace::Benchmark::StorageRunner` (`lib/sentrace/benchmark/storage_runner.rb`) and `bin/rails sentrace:benchmark:storage` measuring database size before/after ingestion, per-event storage bytes, index overhead, write throughput, query/MCP latencies (`SPEC.md` §11 targets), and retention deletion throughput.
- **Internal Administrative JSON Routes (`SPEC.md` §8.1 & §9.3)**:
  - Mount `namespace :internal` routes (`projects`, `issues`, `events`, and `stats`) under `Sentrace::Engine` gated by dedicated MCP bearer authentication by default or a configurable `config.internal_authenticator` host-application policy.
- **Security, Performance & Release Hardening (`SPEC.md` §13, §14, §15)**:
  - Add dedicated security invariant specs (`spec/security/security_invariants_spec.rb`), performance target assertions, full `README.md` configuration/operations documentation, and verify all `SPEC.md` §15 MVP acceptance criteria.

## Capabilities

### New Capabilities
- `event-retention`: Bounded batch deletion of expired error events and delayed cleanup of zero-event orphan issues via ActiveJob and Rake without requiring Redis.
- `storage-observability`: PostgreSQL metadata and aggregate storage statistics plus repeatable storage, throughput, and latency benchmarking.
- `internal-admin-api`: Authenticated `/sentrace/internal` JSON endpoints for engine administration and integration testing with pluggable host authentication policy.

### Modified Capabilities
- `engine-configuration`: Add `retention_batch_size` (default `1000`) and optional callable `internal_authenticator` to `Sentrace::Configuration`.

## Out of Scope

- Web UI dashboards, HTML views, or standalone user account systems (`SPEC.md` §3.2, §9.3).
- Redis, Sidekiq, or external cron/scheduler dependencies (`SPEC.md` §5.7).
- Persisting time-series metric rows to compute storage observability statistics (`SPEC.md` §5.8).
- Transactions, spans, session tracking, replays, structured logs, or external object storage (`SPEC.md` §3.2).

## Impact

- `lib/sentrace/configuration.rb`, `lib/sentrace/retention/cleaner.rb`, `lib/sentrace/storage_stats.rb`, `lib/sentrace/benchmark/storage_runner.rb`, `lib/sentrace.rb`
- `app/jobs/sentrace/retention_cleanup_job.rb`, `app/controllers/sentrace/internal/{base,projects,issues,events,stats}_controller.rb`
- `config/routes.rb`, `lib/tasks/sentrace_{retention,benchmark}.rake`, `README.md`, `SPEC.md`
