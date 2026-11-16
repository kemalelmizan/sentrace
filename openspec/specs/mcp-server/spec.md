# mcp-server Specification

## Purpose
Exposes Sentrace projects, grouped issues, normalized error events, time-bucketed error trends, read-only resources, investigation prompts, and explicit issue status mutations to coding agents over the Model Context Protocol (`stdio` transport).

## Requirements

### Requirement: Standalone local stdio MCP server execution
Sentrace SHALL expose a `bin/rails sentrace:mcp` Rake task that boots an MCP server over `stdio` JSON-RPC using the host application's PostgreSQL connection without requiring a running Rails web server, keeping `stdout` free of non-protocol log output.

#### Scenario: MCP client initializes and discovers server capabilities over stdio
- **WHEN** an MCP client connects to the `sentrace:mcp` `stdio` server and sends `initialize`, `tools/list`, `resources/list`, `resources/templates/list`, and `prompts/list`
- **THEN** the server responds with valid JSON-RPC frames listing all Sentrace tools, static resources, resource templates, and the `investigate_issue` prompt

### Requirement: Environment and project discovery tools
The MCP server SHALL expose `list_environments` and `list_projects` tools returning configured deployment environments (with connection status and without secret tokens) and registered projects with environment attribution.

#### Scenario: Discovering local environment and projects without leaking secrets
- **GIVEN** configured `local` and `staging` (`token: "secret-tok"`) environments and a provisioned project `shop-api`
- **WHEN** a client calls `list_environments` and `list_projects`
- **THEN** `list_environments` returns environment names, transport types, and connectivity status without `"secret-tok"`, and `list_projects` returns `shop-api` attributed to `"local"`

### Requirement: Bounded and paginated issue and event investigation tools
The MCP server SHALL expose `list_issues`, `get_issue`, `list_events`, and `get_event` supporting `environment` and `project_id` scoping, filtering (`status`, `level`, `release`, `platform`, `request_id`, `issue_id`, `since`, `until`), bounded `limit` caps, `request_id` summary attribution, and opaque cursor pagination.

#### Scenario: Filtering and cursor-paginating issues and inspecting issue details
- **GIVEN** three issues in project `1` across different statuses, levels, and releases
- **WHEN** a client calls `list_issues` with `project_id: 1, limit: 2`, follows `next_cursor`, and calls `get_issue` for a returned `issue_id`
- **THEN** `list_issues` returns deterministic non-overlapping pages and `get_issue` returns fingerprint, status, counts, timestamps, release/environment distributions, and recent event references

#### Scenario: Inspecting normalized event details via get_event
- **GIVEN** a stored event in project `1` with stack frames, breadcrumbs, tags, and sanitized contexts
- **WHEN** a client calls `get_event` with `project_id: 1` and the event's `event_id`
- **THEN** `get_event` returns normalized relational attributes alongside `exception`, `breadcrumbs`, `tags`, `contexts`, `request`, and hashed `user`

#### Scenario: Correlating frontend JavaScript and backend Ruby events by request_id and platform
- **GIVEN** project `1` contains a Ruby backend event and a JavaScript frontend event sharing `tags["request_id"] == "req-shared-77"`, plus unrelated events
- **WHEN** a client calls `list_events` with `project_id: 1, request_id: "req-shared-77"` and `list_issues` with `platform: "javascript"`
- **THEN** `list_events` returns both the Ruby and JavaScript events carrying `"request_id" => "req-shared-77"`, and `list_issues` returns only issues seen on `"javascript"`

### Requirement: Query-time error trend aggregation without metric tables
The MCP server SHALL expose `get_error_trends` accepting `environment`, `project_id`, `since`, `until`, and `interval` (`minute`, `hour`, or `day`), computing bucketed occurrence counts directly from `sentrace_events` without creating auxiliary metric tables.

#### Scenario: Computing hourly error counts over a time window
- **GIVEN** error events recorded across two distinct hours for project `1`
- **WHEN** a client calls `get_error_trends` with `project_id: 1, interval: "hour"`
- **THEN** the tool returns ordered time buckets with exact event counts and creates zero database rows

### Requirement: Explicit issue status lifecycle mutation
The MCP server SHALL expose `update_issue_status` as an explicit mutation tool allowing transitions to `unresolved`, `resolved`, or `ignored`, rejecting unsupported status values with validation errors and never exposing arbitrary SQL execution.

#### Scenario: Resolving and ignoring an issue via update_issue_status
- **GIVEN** an `unresolved` issue in project `1`
- **WHEN** a client calls `update_issue_status` with `status: "resolved"` and later `status: "ignored"`
- **THEN** the persisted issue transitions to `resolved` and then `ignored` and returns the updated issue summary

### Requirement: Stable read-only MCP resources and structured investigation prompt
The MCP server SHALL serve read-only JSON resources at `sentrace://environments`, `sentrace://projects`, `sentrace://projects/{project_id}/issues`, `sentrace://issues/{issue_id}`, and `sentrace://events/{event_id}`, plus an `investigate_issue` prompt that separates observed evidence from hypotheses.

#### Scenario: Reading Sentrace resources and rendering the investigate_issue prompt
- **GIVEN** an ingested issue and event in project `1`
- **WHEN** a client reads each `sentrace://` resource URI and requests `prompts/get` for `investigate_issue`
- **THEN** each resource returns scoped JSON with environment attribution, unknown URIs return MCP resource-not-found errors, and `investigate_issue` outlines the 8-step investigation separating observed evidence from hypotheses
