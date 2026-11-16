# storage-foundation Specification

## Purpose
Establishes Sentrace's PostgreSQL schema, uniqueness constraints, targeted indexes, and domain persistence rules for projects, credentials, grouped issues, and bounded JSONB error events.

## Requirements

### Requirement: Project and credential table schema
The database schema SHALL define `sentrace_projects` (`name` up to 120 chars, unique `slug` up to 120 chars, `timestamptz` audit columns) and `sentrace_project_keys` (foreign key to project, unique `public_key` up to 64 chars, nullable `secret_digest`, `active` defaulting to `true`, `created_at`, nullable `revoked_at` as `timestamptz`).

#### Scenario: Persisting a project with unique slug enforcement
- **GIVEN** an existing project with slug `checkout-web`
- **WHEN** another project record with slug `checkout-web` is inserted
- **THEN** persistence fails with a uniqueness constraint violation

#### Scenario: Secret credentials are persisted only as digests
- **WHEN** a project key record is stored with a secret credential
- **THEN** `sentrace_project_keys` stores only the cryptographic digest and never persists a plaintext secret column

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

### Requirement: Bounded JSONB event table schema and deduplication constraint
The database schema SHALL define `sentrace_events` with foreign keys to project and issue, `event_id` (`char(32)`), `occurred_at` and `received_at` (`timestamptz`), nullable `environment` (64), `release` (128), `platform` (32), `logger` (128), and `culprit` (512), `level` (`smallint`), and `event_data` (`jsonb` not null, default `{}`), enforcing uniqueness on `(project_id, event_id)`.

#### Scenario: Structured context is stored inside jsonb without child tables
- **WHEN** an error event with stack frames, breadcrumbs, tags, request metadata, contexts, and hashed user ID is persisted
- **THEN** those structures are stored in `sentrace_events.event_data` as a single `jsonb` document without creating separate frame, breadcrumb, or tag rows

#### Scenario: Duplicate event ID within the same project is rejected
- **GIVEN** an existing event in project `1` with `event_id` `0123456789abcdef0123456789abcdef`
- **WHEN** another event with the same `project_id` and `event_id` is inserted
- **THEN** the database enforces the unique `(project_id, event_id)` constraint

### Requirement: Targeted PostgreSQL indexing without JSONB index bloat
The migrations SHALL create composite indexes on `sentrace_issues (project_id, fingerprint)` (unique), `sentrace_issues (project_id, status, last_seen_at DESC)`, `sentrace_events (project_id, event_id)` (unique), `sentrace_events (issue_id, occurred_at DESC)`, and `sentrace_events (project_id, occurred_at DESC)`, and MUST NOT create GIN indexes on `event_data` or per-tag indexes.

#### Scenario: Schema inspection verifies required indexes and absence of GIN indexes
- **WHEN** engine migrations are applied to a PostgreSQL database
- **THEN** all five specified composite indexes exist with matching column order and sort direction, and zero GIN indexes exist on `sentrace_events.event_data`

### Requirement: Rails 6.1+ migration DDL and PostgreSQL 12+ SQL compatibility
All engine migrations SHALL inherit from `ActiveRecord::Migration[6.1]` and declare timestamp columns via `t.column :<name>, :timestamptz` so migrations execute identically on Rails `6.1`, `7.x`, and `8.x`, and all persistence, retention, statistics, and query SQL MUST execute on `PostgreSQL >= 12` without PostgreSQL 15+ syntax.

#### Scenario: Engine migrations create timestamptz columns on Rails 6.1 through 8.x
- **WHEN** the five engine migrations run against PostgreSQL `>= 12` under Rails `6.1` or Rails `8.x`
- **THEN** every timestamp column on `sentrace_projects`, `sentrace_project_keys`, `sentrace_issues`, `sentrace_events`, and `sentrace_mcp_tokens` has SQL type `timestamp with time zone` without using `t.timestamptz`

#### Scenario: Persistence and query SQL avoids PostgreSQL 15-only constructs
- **WHEN** issue grouping upserts, event deduplication, retention batch deletes, storage stats, and MCP queries execute
- **THEN** all statements use PostgreSQL `>= 12`-compatible SQL (`ON CONFLICT`, `DATE_TRUNC`, `jsonb` operators) and MUST NOT use `MERGE` or `NULLS NOT DISTINCT`
