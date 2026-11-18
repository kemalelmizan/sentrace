## MODIFIED Requirements

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
