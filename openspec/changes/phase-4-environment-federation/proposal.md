# Proposal

## Why

Phase 3 delivered Sentrace's local `stdio` MCP server (`bin/rails sentrace:mcp`), allowing agents to query errors in the local development database. Real-world debugging requires correlating errors across `local`, `staging`, and `production` deployments from one developer session without copying production telemetry into central SaaS storage or exposing database credentials.

## What Changes

- Add dedicated, digest-backed MCP bearer tokens (`sentrace_mcp_tokens` table, `Sentrace::McpToken` model, and `sentrace:mcp:tokens` Rake tasks) completely separate from Sentry ingestion DSN keys, supporting creation, constant-time verification, revocation, and rotation without altering ingestion DSNs.
- Mount `POST /mcp` on `Sentrace::Engine` (`app/controllers/sentrace/mcp_controller.rb`) serving stateless MCP Streamable HTTP via `MCP::Server::Transports::StreamableHTTPTransport`, enforcing HTTPS on non-loopback hosts and dedicated bearer authentication before parsing JSON-RPC payloads.
- Add `deployment_environment` to `Sentrace::Configuration` (defaulting to `Rails.env`) so remote HTTP nodes stamp their logical deployment label on every MCP response without recursive re-federation.
- Implement `Sentrace::Mcp::RemoteHttpClient` (`lib/sentrace/mcp/remote_http_client.rb`) and `Sentrace::Mcp::EnvironmentRouter` (`lib/sentrace/mcp/environment_router.rb`) enabling concurrent cross-environment queries (`environment: "all"` or targeted remote environments), per-environment timeouts, cross-environment fingerprint correlation, and structured partial-failure reporting when a remote deployment is unreachable or unauthorized.

## Capabilities

### New Capabilities
- `mcp-federation`: Remote Streamable HTTP `/sentrace/mcp` endpoint, digest-backed revocable/rotatable MCP bearer tokens, concurrent cross-environment query fan-out, fingerprint correlation, per-environment timeouts, and partial-failure isolation.

### Modified Capabilities
- `engine-configuration`: Add `deployment_environment` attribute identifying a deployment's logical environment label when serving remote MCP requests.

## Impact

- **Database**: Adds migration `db/migrate/20261116000005_create_sentrace_mcp_tokens.rb` (`sentrace_mcp_tokens` with unique `token_digest` index).
- **Models & Controllers**: `app/models/sentrace/mcp_token.rb`, `app/controllers/sentrace/mcp_controller.rb`, `config/routes.rb`.
- **MCP & Tasks**: `lib/sentrace/mcp/{remote_http_client,environment_router,token_manager}.rb`, updates to `lib/sentrace/mcp/dispatcher.rb`, `lib/sentrace/configuration.rb`, and `lib/tasks/sentrace_mcp.rake`.
