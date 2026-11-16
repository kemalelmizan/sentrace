# Spec Delta

## Purpose

Groups related error occurrences into deterministic project-scoped issues using SHA-256 fingerprints while maintaining accurate concurrency-safe occurrence counts and timestamps across environments.

## ADDED Requirements

### Requirement: Deterministic SHA-256 fingerprinting with explicit fingerprint support
Issue fingerprinting SHALL produce a deterministic 64-character SHA-256 hex digest using (1) explicit non-default Sentry `fingerprint` arrays when provided, otherwise (2) exception class plus normalized in-app stack frames (falling back to all frames when no in-app frames exist), otherwise (3) exception class and volatile-stripped message, excluding `environment` so identical bugs correlate across environments.

#### Scenario: Identical exceptions across staging and production produce the same fingerprint
- **WHEN** the same `NoMethodError` with identical application stack frames occurs in `staging` and in `production` (even under different release deploy paths such as `/releases/20261115/app/models/order.rb` vs `/releases/20261116/app/models/order.rb`)
- **THEN** both events compute the exact same SHA-256 fingerprint

#### Scenario: Explicit custom Sentry fingerprint overrides default frame grouping
- **WHEN** two events with different stack frames carry `fingerprint: ["checkout-gateway-timeout"]`
- **THEN** both events compute the same SHA-256 fingerprint and group into a single issue

#### Scenario: Message-only events strip volatile IDs and UUIDs for stable grouping
- **WHEN** two message events without stack frames arrive with `"Order 12345 failed for request 550e8400-e29b-41d4-a716-446655440000"` and `"Order 98765 failed for request 6ba7b810-9dad-11d1-80b4-00c04fd430c8"`
- **THEN** volatile numeric IDs and UUIDs are normalized so both events share one fingerprint

### Requirement: Concurrency-safe issue upsert, counter increment, and regression reopening
Persisting a new (non-duplicate) event SHALL atomically create or update the matching `(project_id, fingerprint)` issue, incrementing `event_count` by `1`, advancing `last_seen_at`, preserving earliest `first_seen_at`, reopening `resolved` issues to `unresolved` while keeping `ignored` issues `ignored`, and guaranteeing zero duplicate issues or lost counts under concurrent ingestion.

#### Scenario: Concurrent ingestion of identical fingerprints creates one issue with exact count
- **WHEN** `10` concurrent threads simultaneously ingest distinct events sharing an identical new fingerprint for the same project
- **THEN** exactly `1` `sentrace_issues` row is created with `event_count == 10` and `10` linked `sentrace_events` rows

#### Scenario: New event reopens a resolved issue but leaves an ignored issue ignored
- **GIVEN** one `resolved` issue and one `ignored` issue in the same project
- **WHEN** a new event arrives for each issue's fingerprint
- **THEN** the `resolved` issue transitions back to `unresolved`, the `ignored` issue remains `ignored`, and both increment `event_count`
