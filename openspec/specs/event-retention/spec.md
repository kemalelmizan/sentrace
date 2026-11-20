# event-retention Specification

## Purpose
Enforces configurable time-based retention on stored error events and orphaned issues using bounded PostgreSQL batch deletes executable via ActiveJob or Rake without external queue dependencies.

## Requirements

### Requirement: Bounded batch deletion of expired error events
`Sentrace::Retention::Cleaner` SHALL delete `sentrace_events` rows whose `occurred_at` or `received_at` precedes `Time.current - config.retention_period` in bounded batches of `config.retention_batch_size`, and MUST NOT immediately delete parent `sentrace_issues` rows when their events expire.

#### Scenario: Pruning expired events across multiple batches preserves parent issues
- **GIVEN** a project issue with 5 expired events (`occurred_at` 45 days ago) and 1 recent event (`occurred_at` 2 days ago) and `retention_batch_size = 2`
- **WHEN** `Sentrace::Retention::Cleaner.run!` executes with `retention_period = 30.days`
- **THEN** the 5 expired events are deleted in bounded batches, the 1 recent event and parent issue remain intact, and `deleted_events_count` equals `5`

#### Scenario: Deleting all events of a recently active issue does not immediately delete the issue
- **GIVEN** an issue whose last event expired (`occurred_at` 31 days ago) while `last_seen_at` is within `orphan_issue_retention_period` (or before orphan cutoff)
- **WHEN** `Sentrace::Retention::Cleaner.run!` deletes the expired event
- **THEN** the event row is removed while the parent `sentrace_issues` row remains retained until its orphan retention window elapses

### Requirement: Delayed cleanup of orphaned issues with zero remaining events
`Sentrace::Retention::Cleaner` SHALL delete `sentrace_issues` rows that have zero remaining `sentrace_events` rows AND whose `last_seen_at` precedes `Time.current - config.orphan_issue_retention_period` in bounded batches.

#### Scenario: Pruning aged orphan issues while retaining issues that still have events
- **GIVEN** an issue with zero remaining events and `last_seen_at` 10 days ago, plus an issue with zero remaining events and `last_seen_at` 2 days ago (`orphan_issue_retention_period = 7.days`)
- **WHEN** `Sentrace::Retention::Cleaner.run!` executes
- **THEN** the 10-day-old orphan issue is deleted and the 2-day-old zero-event issue is retained

### Requirement: Adapter-agnostic ActiveJob and Rake retention entrypoints
Sentrace SHALL provide `Sentrace::Retention::Cleaner.run!` returning a `CleanupResult` struct (`deleted_events_count`, `deleted_orphan_issues_count`, `event_batches`, `issue_batches`, `event_cutoff`, `orphan_issue_cutoff`), `Sentrace::RetentionCleanupJob`, and `bin/rails sentrace:retention:cleanup` (plus documented direct-worker usage) to execute retention cleanup without requiring Redis or a specific job adapter.

#### Scenario: Running retention via ActiveJob and Rake task
- **GIVEN** expired error events in PostgreSQL
- **WHEN** `Sentrace::RetentionCleanupJob.perform_now` or `bin/rails sentrace:retention:cleanup` runs
- **THEN** expired events and eligible orphan issues are pruned cleanly using only PostgreSQL and Rails' built-in ActiveJob interface

#### Scenario: Invoking Cleaner.run! directly from a custom scheduler worker inspects CleanupResult fields
- **GIVEN** 3 expired events and 1 aged orphan issue in PostgreSQL (`retention_batch_size = 2`)
- **WHEN** a custom worker invokes `result = Sentrace::Retention::Cleaner.run!(now: reference_time)`
- **THEN** `result` exposes `deleted_events_count == 3`, `deleted_orphan_issues_count == 1`, `event_batches == 2`, `issue_batches == 1`, and `Time` values for `event_cutoff` and `orphan_issue_cutoff`
