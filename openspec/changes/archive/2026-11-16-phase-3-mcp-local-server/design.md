# Design

## Context

Phases 1 and 2 established `Sentrace::Engine`, PostgreSQL schema/indexes, DSN provisioning, and Sentry-compatible ingestion. Phase 3 exposes this stored error intelligence to coding agents through a local `stdio` MCP server (`bin/rails sentrace:mcp`) built on the official `mcp` Ruby gem (`1.10.0`), while structuring the query and dispatch layer so Phase 4 remote HTTP federation plugs in cleanly.

## Goals / Non-Goals

**Goals:**
- Provide a fast, schema-validated MCP server over `stdio` (`MCP::Server` + `MCP::Server::Transports::StdioTransport`) usable without running `bin/rails server`.
- Enforce strict query bounds (`DEFAULT_LIMIT = 25`, `MAX_LIMIT = 100`), keyset pagination cursors, and strict input validation (`McpInvalidParamsError`) across every tool and resource.
- Stamp `"environment"` attribution on every returned project, issue, event, and trend payload.
- Keep `stdout` 100% clean of Rails/ActiveRecord SQL logs when running `bin/rails sentrace:mcp`.

**Non-Goals:**
- Remote Streamable HTTP `/sentrace/mcp` controller, digest-backed MCP bearer tokens, and cross-deployment HTTP fan-out (scheduled for Phase 4 `phase-4-environment-federation`).

## Decisions

### 1. Layered MCP architecture (`Server` -> `Dispatcher` -> `LocalBackend`)
- **Decision**:
  - `Sentrace::Mcp::LocalBackend`: Stateless PostgreSQL query/mutation executor parameterized by `environment_name` (default `"local"`). Executes indexed ActiveRecord/SQL queries for `list_projects`, `list_issues`, `get_issue`, `update_issue_status`, `list_events`, `get_event`, and `get_error_trends`.
  - `Sentrace::Mcp::Dispatcher`: Validates `environment` against `Sentrace.configuration.environments`, routes `:local` calls to `LocalBackend`, and formats uniform envelopes (`{ environments_queried: [...], results: ..., errors: [...] }`). Phase 4 will extend `Dispatcher` with `EnvironmentRouter` + `RemoteHttpBackend` without changing `Server` tool/resource definitions!
  - `Sentrace::Mcp::Server`: Constructs an `MCP::Server` instance registering all 8 tools (with JSON Schema `input_schema`, `annotations`, and `structured_content` + JSON text fallback), 2 static `MCP::Resource`s, 3 `MCP::ResourceTemplate`s (backed by a unified `resources_read_handler` supporting optional `?environment=&project_id=` query parameters and raising `MCP::Server::ResourceNotFoundError` for missing records), and the `investigate_issue` `MCP::Prompt`.
- **Rationale**: Cleanly decouples protocol framing (`mcp` gem) from environment routing (`Dispatcher`) and PostgreSQL queries (`LocalBackend`), making unit testing fast and Phase 4 federation additive.
- **Alternatives considered**: Putting ActiveRecord queries directly inside `MCP::Tool.define` blocks — rejected because Phase 4 federation needs identical local execution on remote HTTP nodes and merged multi-environment execution in the router.

### 2. Keyset cursor pagination on composite indexes
- **Decision**: Encode pagination cursors as URL-safe Base64 JSON (`{ "ts" => iso8601_microseconds, "id" => integer_id }`):
  - `list_issues` orders by `last_seen_at DESC, id DESC` and filters `(last_seen_at < :ts) OR (last_seen_at = :ts AND id < :id)`, leveraging `index_sentrace_issues_on_project_status_last_seen`.
  - `list_events` orders by `occurred_at DESC, id DESC` and filters `(occurred_at < :ts) OR (occurred_at = :ts AND id < :id)`, leveraging `index_sentrace_events_on_issue_occurred_at` and `index_sentrace_events_on_project_occurred_at`.
  - Fetch `limit + 1` rows to detect `has_more` and emit `next_cursor` without `COUNT(*)` scans.
- **Rationale**: Avoids `OFFSET` scan degradation and duplicate/skipped items when new errors arrive mid-investigation, hitting `< 100 ms` / `< 500 ms` targets in `SPEC.md` §11.
- **Alternatives considered**: Integer page numbers (`OFFSET`) — rejected because newly ingested events shift offsets during active debugging.

### 3. PostgreSQL `date_trunc` query-time aggregation for `get_error_trends`
- **Decision**: Validate `interval` against an explicit allowlist (`"minute"`, `"hour"`, `"day"` — never interpolating untrusted SQL!), map to a safe `CASE`/allowlisted `DATE_TRUNC('hour', occurred_at AT TIME ZONE 'UTC')` expression over `sentrace_events` filtered by `project_id` and `[since, until]` (defaulting `since` to `24.hours.ago` and `until` to `Time.current`), ordered ascending by bucket timestamp.
- **Rationale**: Satisfies `SPEC.md` §7.5 ("computed from event records at query time. No metric observation tables are created") while preventing SQL injection via strict allowlisting.

### 4. `stdio` stream hygiene in `bin/rails sentrace:mcp`
- **Decision**: In `lib/tasks/sentrace_mcp.rake`, redirect `Rails.logger` and `ActiveRecord::Base.logger` to `Logger.new($stderr, level: Logger::WARN)` before opening `MCP::Server::Transports::StdioTransport`, and accept injectable `input:`/`output:` IO streams in a runner helper (`Sentrace::Mcp::StdioRunner`) so integration specs can test full newline-delimited JSON-RPC sessions deterministically in-process or via subprocess pipes.
- **Rationale**: Prevents `RAILS_LOG_TO_STDOUT=true` or SQL debug logs from corrupting `$stdout` JSON-RPC frames.

## Risks / Trade-offs

- **[Dual `event_id` lookup ambiguity (`char(32)` hex vs numeric `id`)]** → Support both 32-character hex `event_id` (primary Sentry ID) and integer database `id` in `get_event` and `sentrace://events/{event_id}`, preferring `event_id` match when 32-hex and requiring/applying `project_id` scope when supplied.
- **[Large event lists blowing agent context windows]** → Omit full `event_data` stack traces/breadcrumbs in `list_events` summaries (returning relational metadata + exception summary + `event_id` reference), reserving full frames/breadcrumbs/contexts for `get_event` and `sentrace://events/{event_id}`.

## Migration Plan

No database schema migrations required. Adding `lib/sentrace/mcp/*` and `lib/tasks/sentrace_mcp.rake` enables `bin/rails sentrace:mcp` immediately for existing Phase 1/2 installations.
