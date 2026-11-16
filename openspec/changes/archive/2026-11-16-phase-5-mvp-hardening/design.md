# Design

## Context

Phases 1–4 implemented Sentrace's PostgreSQL engine schema, Sentry envelope ingestion, issue grouping, local `stdio` MCP server, and federated Streamable HTTP MCP router. Phase 5 completes all remaining MVP requirements in `SPEC.md` (§5.7, §5.8, §8.1, §8.3, §11, §11.1, §13, §14, §15): bounded retention cleanup, PostgreSQL storage observability, internal administrative routes, repeatable storage/latency benchmarking, security verification, and documentation.

## Goals / Non-Goals

**Goals:**
- Prune expired `sentrace_events` and aged zero-event `sentrace_issues` in bounded SQL batches without long table locks or Redis dependencies.
- Compute `SPEC.md` §5.8 storage statistics purely from PostgreSQL system catalogs (`pg_table_size`, `pg_indexes_size`, `pg_total_relation_size`) and lightweight SQL aggregates without writing metric rows.
- Expose `SPEC.md` §8.1 `/sentrace/internal/*` routes securely by default via `Sentrace::McpToken` while letting host apps plug in `config.internal_authenticator` (`SPEC.md` §9.3).
- Provide a deterministic, self-cleaning `Sentrace::Benchmark::StorageRunner` measuring storage per event, index overhead, throughput, and `SPEC.md` §11 latency targets.

**Non-Goals:**
- HTML views or browser UI dashboards (`SPEC.md` §3.2).
- Background scheduler daemons or Redis queue adapters (`SPEC.md` §5.7).

## Decisions

### 1. Bounded Subquery `DELETE` Loops in `Sentrace::Retention::Cleaner`
- **Decision**: Execute looped batch deletes using `DELETE FROM sentrace_events WHERE id IN (SELECT id FROM sentrace_events WHERE occurred_at < :cutoff ORDER BY occurred_at ASC LIMIT :batch_size)` until `0` rows are affected, followed by `DELETE FROM sentrace_issues WHERE id IN (SELECT i.id FROM sentrace_issues i WHERE i.last_seen_at < :orphan_cutoff AND NOT EXISTS (SELECT 1 FROM sentrace_events e WHERE e.issue_id = i.id) LIMIT :batch_size)`.
- **Rationale**: Uses `index_sentrace_events_on_issue_occurred_at` / `occurred_at` scans cleanly, bounds WAL and row-lock duration per batch (`default: 1000`), never cascades issue deletion prematurely when events expire, and only deletes orphaned issues once both zero events remain AND `last_seen_at < orphan_cutoff`.

### 2. Zero-Table Storage Observability via PostgreSQL Catalogs & Issue Occurrence Delta
- **Decision**: `Sentrace::StorageStats.collect` queries:
  - `COUNT(*)`, `MIN(occurred_at)`, `MAX(occurred_at)` on `sentrace_events`.
  - `COUNT(*)` and `COALESCE(SUM(event_count), 0)` on `sentrace_issues`.
  - `events_removed_by_retention = GREATEST(sum_issue_event_count - total_events, 0)` (plus `pg_stat_user_tables` tuple delete metadata for reference), because `sentrace_issues.event_count` tracks cumulative ingested occurrences while `sentrace_events` holds currently retained occurrences.
  - `pg_table_size(rel)`, `pg_indexes_size(rel)`, and `pg_total_relation_size(rel)` across the five `sentrace_` tables.
  - Daily event counts grouped by `DATE_TRUNC('day', occurred_at AT TIME ZONE 'UTC')` over a bounded window (default 30 days).
- **Rationale**: Directly satisfies `SPEC.md` §5.8 ("Do not persist individual metric observations to calculate these values. Use PostgreSQL metadata and aggregate queries").

### 3. Secure-by-Default `/sentrace/internal` Controllers with Pluggable Host Policy
- **Decision**: Create `Sentrace::Internal::BaseController < ApplicationController` enforcing `before_action :authenticate_internal_request!`. When `config.internal_authenticator` is set, invoke `config.internal_authenticator.call(request)`; otherwise require a valid `Authorization: Bearer <snt_mcp_token>`.
- **Rationale**: Prevents accidental unauthenticated exposure of `/sentrace/internal/*` when mounted in production while honoring `SPEC.md` §9.3 ("If a host application later exposes administrative routes, it may integrate its existing authentication and authorization policies").

### 4. Self-Cleaning PostgreSQL Storage & Latency Benchmark
- **Decision**: `Sentrace::Benchmark::StorageRunner` creates a dedicated temporary project (`sentrace-benchmark-<hex>`), runs `VACUUM ANALYZE` on `sentrace_` tables before and after ingesting `N` synthetic multi-frame/breadcrumb/tag events, measures parse, persist, lookup, MCP `list_issues`, and batch retention deletion timings with `Process.clock_gettime(Process::CLOCK_MONOTONIC)`, and removes benchmark artifacts in an `ensure` block (unless `cleanup: false`).
- **Rationale**: Produces accurate PostgreSQL heap/TOAST/B-tree byte measurements (`SPEC.md` §11.1) without leaving synthetic benchmark noise in developer databases.

## Risks / Trade-offs

- **[`VACUUM` cannot run inside an open SQL transaction block]** → In `StorageRunner`, check `ActiveRecord::Base.connection.open_transactions.zero?` before issuing `VACUUM ANALYZE` on `sentrace_` tables so the benchmark works both standalone (`bin/rails sentrace:benchmark:storage`) and inside RSpec specs!
