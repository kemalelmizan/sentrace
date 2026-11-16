# internal-admin-api Specification

## Purpose
Exposes authenticated `/sentrace/internal` administrative JSON endpoints for managing projects, inspecting and updating issues, inspecting events, and retrieving storage statistics.

## Requirements

### Requirement: Authenticated internal administrative JSON routes
`Sentrace::Engine` SHALL expose `/internal/projects`, `/internal/issues` (`index`, `show`, `update`), `/internal/events` (`index`, `show`), and `/internal/stats` (`show`) protected with MCP bearer token authentication or `config.internal_authenticator`, emitting `Cache-Control: no-store` on all responses, enforcing bounded pagination, and returning numeric HTTP `422` for validation or parameter errors across Rack `>= 2.2`.

#### Scenario: Managing projects, issues, events, and stats with bearer authentication
- **GIVEN** an active `Sentrace::McpToken` (or custom `config.internal_authenticator`)
- **WHEN** an authenticated client calls `/sentrace/internal/projects`, `/sentrace/internal/issues`, `/sentrace/internal/events`, and `/sentrace/internal/stats`
- **THEN** every response includes `Cache-Control: no-store` and returns bounded project, issue, event, and storage payloads without exposing secret digests

#### Scenario: Invalid project or query parameters return HTTP 422 on Rack 2.2 and 3.x
- **GIVEN** an authenticated internal API client
- **WHEN** the client posts `/sentrace/internal/projects` with a blank `slug` or requests `/sentrace/internal/issues?status=invalid`
- **THEN** the endpoint responds with HTTP `422` and `Cache-Control: no-store` without raising Rack status symbol errors

#### Scenario: Unauthenticated internal requests are rejected
- **WHEN** a client requests `/sentrace/internal/projects` or `/sentrace/internal/issues` without valid credentials (or with an ingestion DSN public key)
- **THEN** the endpoint responds with HTTP `401` and `Cache-Control: no-store`
