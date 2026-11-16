# storage-observability Specification

## Purpose
Provides PostgreSQL catalog and aggregate storage observability statistics alongside a repeatable storage, throughput, and query-latency benchmark without persisting metric rows.

## Requirements

### Requirement: PostgreSQL-derived storage observability statistics
`Sentrace::StorageStats` SHALL report total events, total issues, daily event counts, approximate PostgreSQL storage bytes (`table_bytes`, `index_bytes`, `total_bytes`), oldest retained event timestamp, and events removed by retention using PostgreSQL catalog metadata and aggregate queries, and MUST NOT persist individual metric rows.

#### Scenario: Inspecting storage statistics after ingestion and retention pruning
- **GIVEN** a project with 4 ingested events where 2 expired events were subsequently removed by retention
- **WHEN** `Sentrace::StorageStats.collect` is called
- **THEN** it returns `total_events: 2`, `total_issues: 1`, `events_removed_by_retention: 2`, positive `database_storage_bytes`, `oldest_retained_event_at`, and daily event buckets without creating any metric records

### Requirement: Repeatable PostgreSQL storage and latency benchmark
`Sentrace::Benchmark::StorageRunner` (and `bin/rails sentrace:benchmark:storage`) SHALL generate a repeatable workload of representative error events and measure database size before and after ingestion, average bytes per event, index overhead, write throughput, issue/event/MCP query latencies, and retention deletion throughput.

#### Scenario: Executing the storage benchmark reports size deltas, latencies, and throughput
- **WHEN** `Sentrace::Benchmark::StorageRunner.run(event_count: 100)` executes against PostgreSQL
- **THEN** it returns structured measurements including `db_bytes_before`, `db_bytes_after`, `avg_bytes_per_event`, `index_overhead_bytes`, `write_events_per_second`, parse/persist/query latencies meeting `SPEC.md` §11 targets, and `retention_delete_events_per_second`
