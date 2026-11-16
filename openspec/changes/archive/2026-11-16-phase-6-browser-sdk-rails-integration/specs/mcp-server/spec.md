# mcp-server Specification

## MODIFIED Requirements

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
