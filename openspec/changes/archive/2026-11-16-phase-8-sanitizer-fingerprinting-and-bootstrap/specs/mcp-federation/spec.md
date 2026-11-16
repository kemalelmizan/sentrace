# mcp-federation Specification (Delta)

## MODIFIED Requirements

### Requirement: Dedicated digest-backed MCP bearer credentials
Remote MCP authentication SHALL use dedicated `snt_mcp_` bearer tokens stored exclusively as SHA-256 digests in `sentrace_mcp_tokens`, supporting `issue!`, idempotent `ensure!` (validating prefix and minimum entropy without storing plaintext or resurrecting revoked tokens), constant-time verification, revocation, and rotation while rejecting ingestion DSN public keys.

#### Scenario: Issuing, authenticating, rotating, and revoking MCP tokens independently of DSNs
- **GIVEN** a project with an active ingestion DSN key and a newly issued MCP bearer token
- **WHEN** the MCP token is rotated via `Sentrace::McpToken.rotate!`
- **THEN** only SHA-256 digests are persisted, the previous MCP token is revoked, the new MCP token authenticates, the ingestion DSN public key is rejected on `/sentrace/mcp`, and the project's ingestion DSN continues to work unchanged

#### Scenario: Declarative McpToken.ensure! idempotently seeds an environment-provided snt_mcp_ token as digest only
- **WHEN** `Sentrace::McpToken.ensure!(name: "staging", token: "snt_mcp_0123456789abcdef0123456789abcdef")` is invoked repeatedly
- **THEN** only `token_prefix` and the SHA-256 `token_digest` are persisted, `McpToken.authenticate` succeeds for that token, repeated calls return the existing active record without creating duplicates, and short, unprefixed, or revoked tokens raise `ArgumentError`
