# mcp-federation Specification

## MODIFIED Requirements

### Requirement: Authenticated Streamable HTTP MCP endpoint with HTTPS enforcement
Each Sentrace deployment SHALL expose `POST /mcp` (mounted e.g. at `/sentrace/mcp`) speaking stateless MCP Streamable HTTP, emitting `Cache-Control: no-store` on all responses, requiring valid `Authorization: Bearer <token>` authentication before payload processing, and rejecting non-HTTPS requests on non-loopback hosts.

#### Scenario: Valid bearer token executes MCP tool calls over HTTPS Streamable HTTP
- **GIVEN** an active MCP bearer token on a deployment configured with `deployment_environment = "staging"`
- **WHEN** a client posts a Streamable HTTP `tools/call` request to `https://staging.example.com/sentrace/mcp` with `Authorization: Bearer <token>`
- **THEN** the endpoint responds with HTTP `200`, `Cache-Control: no-store`, and MCP JSON-RPC results attributed to `"staging"`

#### Scenario: Unauthenticated or non-HTTPS remote requests are rejected
- **WHEN** a client posts to `https://staging.example.com/sentrace/mcp` without a valid bearer token or to `http://staging.example.com/sentrace/mcp` over plain HTTP
- **THEN** unauthenticated requests receive HTTP `401` and plain-HTTP non-loopback requests receive HTTP `403`, both carrying `Cache-Control: no-store` without executing MCP handlers
