# storage-foundation Specification

## ADDED Requirements

### Requirement: Rails 6.1+ migration DDL and PostgreSQL 12+ SQL compatibility
All engine migrations SHALL inherit from `ActiveRecord::Migration[6.1]` and declare timestamp columns via `t.column :<name>, :timestamptz` so migrations execute identically on Rails `6.1`, `7.x`, and `8.x`, and all persistence, retention, statistics, and query SQL MUST execute on `PostgreSQL >= 12` without PostgreSQL 15+ syntax.

#### Scenario: Engine migrations create timestamptz columns on Rails 6.1 through 8.x
- **WHEN** the five engine migrations run against PostgreSQL `>= 12` under Rails `6.1` or Rails `8.x`
- **THEN** every timestamp column on `sentrace_projects`, `sentrace_project_keys`, `sentrace_issues`, `sentrace_events`, and `sentrace_mcp_tokens` has SQL type `timestamp with time zone` without using `t.timestamptz`

#### Scenario: Persistence and query SQL avoids PostgreSQL 15-only constructs
- **WHEN** issue grouping upserts, event deduplication, retention batch deletes, storage stats, and MCP queries execute
- **THEN** all statements use PostgreSQL `>= 12`-compatible SQL (`ON CONFLICT`, `DATE_TRUNC`, `jsonb` operators) and MUST NOT use `MERGE` or `NULLS NOT DISTINCT`

## MODIFIED Requirements

### Requirement: Grouped issue table schema and lifecycle statuses
The database schema SHALL define `sentrace_issues` (`project_id`, `fingerprint` <= 64, `status` `unresolved: 0` / `resolved: 1` / `ignored: 2`, `smallint` `level`, nullable `exception_type` <= 255 and `message` <= 1024, `timestamptz` `first_seen_at` and `last_seen_at`, `bigint` `event_count` default `0`), enforcing unique `(project_id, fingerprint)` and validating enums across ActiveRecord `6.1`–`8.x`.

#### Scenario: Duplicate fingerprint within the same project is rejected
- **GIVEN** an existing issue for project `1` with fingerprint `abc123`
- **WHEN** a second issue row is inserted for project `1` with fingerprint `abc123`
- **THEN** the database rejects the duplicate `(project_id, fingerprint)` pair

#### Scenario: Identical fingerprint across separate projects is allowed
- **GIVEN** an existing issue for project `1` with fingerprint `abc123`
- **WHEN** an issue with fingerprint `abc123` is inserted for project `2`
- **THEN** both issue records are stored independently

#### Scenario: Issue status transitions across supported lifecycle states
- **GIVEN** an existing issue initialized as `unresolved`
- **WHEN** its status transitions to `resolved` or `ignored`, or an unsupported status/level such as `:archived` is assigned
- **THEN** valid transitions persist as `smallint` values and unsupported enum assignments mark the record invalid via ActiveModel validations across ActiveRecord `6.1`, `7.x`, and `8.x` without raising `ArgumentError`
