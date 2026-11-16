# internal-admin-api Specification

## Purpose
Exposes authenticated `/sentrace/internal` administrative JSON endpoints for managing projects, inspecting and updating issues, inspecting events, and retrieving storage statistics.

## Requirements

### Requirement: Authenticated internal administrative JSON routes
`Sentrace::Engine` SHALL expose `/internal/projects`, `/internal/issues` (`index`, `show`, `update`), `/internal/events` (`index`, `show`), and `/internal/stats` (`show`) protected by default with dedicated MCP bearer token authentication or a host-supplied `config.internal_authenticator` callable, and MUST enforce bounded pagination on list endpoints.

#### Scenario: Managing projects, issues, events, and stats with bearer authentication
- **GIVEN** an active `Sentrace::McpToken` (or custom `config.internal_authenticator`)
- **WHEN** an authenticated client calls `/sentrace/internal/projects`, `/sentrace/internal/issues`, `/sentrace/internal/events`, and `/sentrace/internal/stats`
- **THEN** the endpoints manage projects, list/show/update issues, list/show normalized events with bounded limits, and return PostgreSQL storage statistics without exposing secret digests

#### Scenario: Unauthenticated internal requests are rejected
- **WHEN** a client requests `/sentrace/internal/projects` or `/sentrace/internal/issues` without valid credentials (or with an ingestion DSN public key)
- **THEN** the endpoint responds with HTTP `401 Unauthorized`
