# Design

## Context

Phase 3 built `Sentrace::Mcp::LocalBackend`, `Sentrace::Mcp::Dispatcher`, and `Sentrace::Mcp::Server` for local `stdio` use. Phase 4 completes Sentrace's federated architecture: each deployed Rails app (`staging`, `production`) exposes an authenticated `/sentrace/mcp` Streamable HTTP endpoint backed by its own PostgreSQL database, and the developer's local `stdio` MCP server federates queries across them concurrently with strict timeouts and failure isolation.

## Goals / Non-Goals

**Goals:**
- Keep MCP credentials (`sentrace_mcp_tokens`, SHA-256 digested, revocable, rotatable) strictly isolated from Sentry ingestion `ProjectKey` DSNs.
- Use `MCP::Server::Transports::StreamableHTTPTransport` (`stateless: true, enable_json_response: true, dns_rebinding_protection: false, serve_subscriptions_listen: false`) inside `Sentrace::McpController` after HTTPS and bearer-token gates.
- Implement zero-extra-dependency `Net::HTTP` federation in `Sentrace::Mcp::RemoteHttpClient` with injectable transport hooks for fast, deterministic multi-node specs.
- Fan out `environment: "all"` queries concurrently via `Sentrace::Mcp::EnvironmentRouter` with per-environment timeouts, merged result sets, cross-environment fingerprint correlation, and structured error categories (`timeout`, `authentication_failed`, `unreachable`, `protocol_error`, `remote_tool_error`).

**Non-Goals:**
- Server-initiated SSE push subscriptions across federated nodes (stateless request/response JSON over Streamable HTTP satisfies all `SPEC.md` §7 tools, resources, and prompts cleanly without holding idle Puma worker threads).
- Recursive multi-hop federation (remote HTTP nodes serve only their own local PostgreSQL database).

## Decisions

### 1. Digest-only `sentrace_mcp_tokens` table & constant-time bearer verification
- **Decision**: Create `sentrace_mcp_tokens` storing `name`, non-secret `token_prefix` (first 12 chars e.g. `"snt_mcp_4f8a"`), unique `token_digest` (`OpenSSL::Digest::SHA256.hexdigest(raw_token)`), `active`, `last_used_at`, `revoked_at`, and `created_at`. Generate tokens formatted as `"snt_mcp_<48-hex>"` (`24` random bytes). Verify incoming `Authorization: Bearer <token>` by computing its SHA-256 hex digest, loading active unrevoked candidate(s), and comparing digests with `ActiveSupport::SecurityUtils.secure_compare`.
- **Rationale**: Satisfies `SPEC.md` §7.8, §9.2, and §13 ("Stored as digests", "Revocable", "Scoped to the deployment", "Rotatable without changing ingestion DSNs", "Ingestion credentials and MCP credentials serve separate purposes").

### 2. Node-local `Dispatcher` inside `Sentrace::McpController`
- **Decision**: When `Sentrace::McpController#handle` processes an authenticated Streamable HTTP request, it constructs a node-scoped `Configuration` where `environments = { <deployment_environment>: { transport: :local } }` (with no `:http` hops) and passes it to `Sentrace::Mcp::Server.build` + `StreamableHTTPTransport`.
- **Rationale**: Guarantees two critical invariants simultaneously: (1) every item returned by the remote node carries `"environment" => config.deployment_environment` (e.g. `"staging"` or `"production"`), and (2) a remote node can never be tricked into SSRF or infinite federation loops even if its initializer also lists `:http` environments!

### 3. Concurrent fan-out and semantic result merging in `EnvironmentRouter`
- **Decision**:
  - Single `:http` target: `RemoteHttpClient#call_environment(env_def, operation, **kwargs)` translates the backend operation + kwargs into a stateless MCP `tools/call` JSON-RPC POST to `env_def.url` with `Authorization: Bearer <token>` and `open_timeout = read_timeout = write_timeout = env_def.timeout`, unwrapping `result.structuredContent` (or JSON text fallback).
  - Multi-environment (`environment: "all"`): Spawn one bounded thread per target environment (wrapping ActiveRecord connection checkout cleanly via `Rails.application.executor.wrap` / `connection_pool.with_connection` on `:local` threads!), join all threads, and merge compatible results:
    - `list_projects`: flat merged `"projects"` + `"environments_queried"` + `"errors"`.
    - `list_issues`: merged `"issues"` sorted by `last_seen_at DESC`, plus `"fingerprint_correlations"` listing fingerprints present in `>= 2` environments (`{ "fingerprint" => fp, "environments" => [...], "total_event_count" => sum }`), plus `"environments_queried"` and `"errors"`.
    - `list_events`: merged `"events"` sorted by `occurred_at DESC` + `"environments_queried"` + `"errors"`.
    - `get_error_trends`: `"series"` keyed/listed per environment + `"total_events"` + `"environments_queried"` + `"errors"`.
    - `get_issue` / `get_event`: `"matches"` array across reachable environments + `"environments_queried"` + `"errors"`.
- **Rationale**: Directly fulfills `SPEC.md` §7.4 ("Merge compatible result sets", "Preserve environment attribution", "Avoid silently treating an unavailable environment as an empty result", "Prevent one remote environment from blocking the entire response indefinitely").

## Risks / Trade-offs

- **[Thread safety of ActiveRecord connections during concurrent fan-out]** → Wrap `:local` execution inside `ActiveRecord::Base.connection_pool.with_connection` when running in worker threads so connections are always returned to the pool cleanly.
- **[Plain HTTP used in local integration/development setups]** → Allow `http://` only for loopback hosts (`localhost`, `127.0.0.1`, `::1`, `[::1]`) in both `Sentrace::McpController` and `RemoteHttpClient`, rejecting plain `http://` for any non-loopback hostname (`403` on server, `McpRemoteError` category `"insecure_transport"` on client).

## Migration Plan

Run `bin/rails db:migrate` (or copy migration via `sentrace:install`) to create `sentrace_mcp_tokens`, then issue a deployment token via `bin/rails "sentrace:mcp:tokens:create[default]"`.
