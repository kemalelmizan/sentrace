# internal-admin-api Specification

## Purpose
Exposes authenticated `/sentrace/internal` administrative JSON endpoints for managing projects, inspecting and updating issues, inspecting events, and retrieving storage statistics.

## Requirements

### Requirement: Authenticated internal administrative JSON routes
`Sentrace::Engine` SHALL expose `/internal/projects`, `/internal/issues`, `/internal/events`, and `/internal/stats` protected by MCP bearer tokens or `config.internal_authenticator`, emitting defensive security headers (`Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`), rejecting cross-origin or unverified cookie-CSRF requests with HTTP `403`, and returning numeric HTTP `422` for validation, non-scalar, or range errors.

#### Scenario: Managing projects, issues, events, and stats with bearer authentication
- **GIVEN** an active `Sentrace::McpToken` (or custom `config.internal_authenticator`)
- **WHEN** an authenticated client calls `/sentrace/internal/projects`, `/sentrace/internal/issues`, `/sentrace/internal/events`, and `/sentrace/internal/stats`
- **THEN** every response includes `Cache-Control: no-store` and `X-Content-Type-Options: nosniff` and returns bounded project, issue, event, and storage payloads without exposing secret digests

#### Scenario: Invalid, non-scalar, or out-of-range parameters return HTTP 422 on Rack 2.2 and 3.x
- **GIVEN** an authenticated internal API client
- **WHEN** the client posts `/sentrace/internal/projects` with a blank `slug`, patches a project with a nested Hash `name`, requests `/sentrace/internal/issues?status=invalid`, or requests `/sentrace/internal/stats?days=999999`
- **THEN** the endpoint responds with HTTP `422` and `Cache-Control: no-store` without raising unhandled `ForbiddenAttributesError`, `RangeError`, or Rack status symbol errors

#### Scenario: Cross-origin and cookie-based CSRF requests to internal routes are rejected with HTTP 403
- **GIVEN** a host-provided `config.internal_authenticator` reading session cookies
- **WHEN** a browser sends a cross-origin request (`Origin: https://evil.example.com`) or a form-encoded `POST /sentrace/internal/projects` carrying a `Cookie` without a same-origin `Origin`, `application/json` content type, or `X-CSRF-Token`
- **THEN** the endpoint responds with HTTP `403` before mutating any state

#### Scenario: Unauthenticated internal requests are rejected
- **WHEN** a client requests `/sentrace/internal/projects` or `/sentrace/internal/issues` without valid credentials (or with an ingestion DSN public key)
- **THEN** the endpoint responds with HTTP `401` and `Cache-Control: no-store`
