# Proposal

## Why

With PostgreSQL storage, Sentry-compatible ingestion, sanitization, and atomic issue grouping complete in Phases 1–2, Sentrace needs its primary developer-facing interface: a local Model Context Protocol (MCP) server (`bin/rails sentrace:mcp`) speaking `stdio` JSON-RPC so coding agents can discover environments and projects, inspect grouped issues and normalized events, analyze error trends, follow structured investigation prompts, and explicitly mutate issue lifecycle status (`unresolved`, `resolved`, `ignored`).

## What Changes

- Implement `Sentrace::Mcp::LocalBackend` (`lib/sentrace/mcp/local_backend.rb`) providing bounded, keyset-paginated PostgreSQL queries and lifecycle mutations with explicit environment attribution, strict parameter validation, and zero raw credential or unrestricted SQL exposure.
- Implement `Sentrace::Mcp::Dispatcher` (`lib/sentrace/mcp/dispatcher.rb`) routing MCP operations by `environment` label (`local` default) with clean extension seams for Phase 4 remote HTTP federation.
- Implement `Sentrace::Mcp::Server` (`lib/sentrace/mcp/server.rb`) wrapping the official `mcp` Ruby SDK (`~> 1.0`) to expose:
  - **Discovery tools**: `list_environments`, `list_projects`
  - **Issue tools**: `list_issues`, `get_issue`, `update_issue_status`
  - **Event & trend tools**: `list_events`, `get_event`, `get_error_trends`
  - **Read-only resources & templates**: `sentrace://environments`, `sentrace://projects`, `sentrace://projects/{project_id}/issues`, `sentrace://issues/{issue_id}`, `sentrace://events/{event_id}`
  - **Prompt**: `investigate_issue` distinguishing observed evidence from testable hypotheses across an 8-step investigation workflow.
- Add `bin/rails sentrace:mcp` Rake task (`lib/tasks/sentrace_mcp.rake`) running `MCP::Server::Transports::StdioTransport` cleanly outside a running Rails web process with stdout reserved strictly for JSON-RPC frames.

## Capabilities

### New Capabilities
- `mcp-server`: Local `stdio` MCP server, discovery/issue/event/trend tools, keyset pagination, read-only `sentrace://` resources, `investigate_issue` prompt, and explicit `update_issue_status` mutation.

### Modified Capabilities
- None.

## Impact

- **Added modules**: `lib/sentrace/mcp/{local_backend,dispatcher,server}.rb`, `lib/tasks/sentrace_mcp.rake`.
- **Modified files**: `lib/sentrace/errors.rb` (`McpError`, `McpInvalidParamsError`, `McpNotFoundError`), `lib/sentrace.rb`, `README.md`.
- **Database**: Zero schema migrations required; uses Phase 1 composite indexes (`index_sentrace_issues_on_project_status_last_seen`, `index_sentrace_events_on_issue_occurred_at`, `index_sentrace_events_on_project_occurred_at`).
