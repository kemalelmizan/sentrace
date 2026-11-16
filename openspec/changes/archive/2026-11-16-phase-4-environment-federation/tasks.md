# Tasks

## 1. Digest-Backed MCP Bearer Tokens & Rake Management

- [x] 1.1 Create `sentrace_mcp_tokens` migration (`db/migrate/20261116000005_create_sentrace_mcp_tokens.rb`), `Sentrace::McpToken` model (`app/models/sentrace/mcp_token.rb`), `Sentrace::Mcp::TokenManager` (`lib/sentrace/mcp/token_manager.rb`), and Rake tasks (`sentrace:mcp:tokens`, `sentrace:mcp:tokens:create[name]`, `sentrace:mcp:tokens:rotate[name]`, `sentrace:mcp:tokens:revoke[id]`), and verify model, schema, and Rake specs pass

## 2. Remote Streamable HTTP Endpoint (`/sentrace/mcp`)

- [x] 2.1 Add `deployment_environment` to `Sentrace::Configuration` and mount `POST /mcp` (`config/routes.rb`, `app/controllers/sentrace/mcp_controller.rb`) using `MCP::Server::Transports::StreamableHTTPTransport` with non-loopback HTTPS enforcement (`403`), constant-time bearer token verification (`401`), ingestion-DSN rejection (`401`), and node-local query scoping, and verify request specs pass

## 3. Remote HTTP Client, Concurrent EnvironmentRouter & Federation Specs

- [x] 3.1 Implement `Sentrace::Mcp::RemoteHttpClient` (`lib/sentrace/mcp/remote_http_client.rb`) and `Sentrace::Mcp::EnvironmentRouter` (`lib/sentrace/mcp/environment_router.rb`) wired into `Sentrace::Mcp::Dispatcher` for concurrent cross-environment queries, merged results with fingerprint correlations, per-environment timeouts, and partial-failure error categories without credential leakage, and verify multi-environment federation, timeout, and partial-failure integration specs pass

## Workflow follow-up

- Run `openspec validate --all --strict --no-interactive`, verify full RSpec + RuboCop suites, and archive `phase-4-environment-federation`.
- Propose `phase-5-mvp-hardening` next following `SPEC.md` §16.
