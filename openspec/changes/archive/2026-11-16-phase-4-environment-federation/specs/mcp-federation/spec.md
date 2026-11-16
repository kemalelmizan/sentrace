# Spec Delta

## Purpose

Enables authenticated remote MCP Streamable HTTP access to individual Sentrace deployments and federates queries across local, staging, and production environments with timeout and partial-failure isolation.

## ADDED Requirements

### Requirement: Dedicated digest-backed MCP bearer credentials
Remote MCP authentication SHALL use dedicated bearer tokens stored exclusively as cryptographic SHA-256 digests in `sentrace_mcp_tokens`, supporting creation, constant-time verification, revocation, and rotation without altering project ingestion DSN keys, and MUST reject ingestion DSN public keys as MCP credentials.

#### Scenario: Issuing, authenticating, rotating, and revoking MCP tokens independently of DSNs
- **GIVEN** a project with an active ingestion DSN key and a newly issued MCP bearer token
- **WHEN** the MCP token is rotated via `Sentrace::McpToken.rotate!`
- **THEN** only SHA-256 digests are persisted, the previous MCP token is revoked, the new MCP token authenticates, the ingestion DSN public key is rejected on `/sentrace/mcp`, and the project's ingestion DSN continues to work unchanged

### Requirement: Authenticated Streamable HTTP MCP endpoint with HTTPS enforcement
Each Sentrace deployment SHALL expose `POST /mcp` (mounted e.g. at `/sentrace/mcp`) speaking stateless MCP Streamable HTTP, requiring valid `Authorization: Bearer <token>` authentication before payload processing and rejecting non-HTTPS requests on non-loopback hosts.

#### Scenario: Valid bearer token executes MCP tool calls over HTTPS Streamable HTTP
- **GIVEN** an active MCP bearer token on a deployment configured with `deployment_environment = "staging"`
- **WHEN** a client posts a Streamable HTTP `tools/call` request to `https://staging.example.com/sentrace/mcp` with `Authorization: Bearer <token>`
- **THEN** the endpoint responds with HTTP `200` and MCP JSON-RPC results attributed to `"staging"`

#### Scenario: Unauthenticated or non-HTTPS remote requests are rejected
- **WHEN** a client posts to `https://staging.example.com/sentrace/mcp` without a valid bearer token or to `http://staging.example.com/sentrace/mcp` over plain HTTP
- **THEN** unauthenticated requests receive HTTP `401` and plain-HTTP non-loopback requests receive HTTP `403` without executing MCP handlers

### Requirement: Concurrent cross-environment federation and result merging
The local MCP router SHALL route requests to a selected remote environment or concurrently across all configured environments (`environment: "all"`), merging compatible project, issue, event, and trend results while preserving per-record environment attribution and correlating matching issue fingerprints across environments.

#### Scenario: Querying issues across local, staging, and production correlates shared fingerprints
- **GIVEN** identical fingerprinted issues in `local`, `staging`, and `production`
- **WHEN** an MCP client calls `list_issues` with `environment: "all"`
- **THEN** the router queries all three environments concurrently, returns merged issues preserving each item's `environment` label, and reports cross-environment fingerprint correlations

### Requirement: Per-environment timeouts and partial-failure isolation
Federation requests SHALL enforce each remote environment's configured timeout and SHALL isolate unavailable, timed-out, or unauthorized remote environments by returning reachable environments' results alongside structured per-environment failure categories without leaking federation tokens.

#### Scenario: Timed-out staging environment does not block local and production results
- **GIVEN** `local` (`:local`), `staging` (`:http`, `timeout: 0.1` seconds, hanging), and `production` (`:http`, healthy)
- **WHEN** an MCP client calls `list_issues` with `environment: "all"`
- **THEN** the response completes promptly with `local` and `production` issues plus an explicit `errors` entry identifying `staging` with category `"timeout"` and zero leaked credentials
