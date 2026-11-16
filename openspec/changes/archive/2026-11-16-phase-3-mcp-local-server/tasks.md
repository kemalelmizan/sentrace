# Tasks

## 1. Local Query Backend, Cursor Pagination & Dispatcher

- [x] 1.1 Implement `Sentrace::Mcp::LocalBackend` (`lib/sentrace/mcp/local_backend.rb`) and MCP error classes (`lib/sentrace/errors.rb`) supporting `list_projects`, `list_issues`, `get_issue`, `update_issue_status`, `list_events`, `get_event`, and `get_error_trends` with keyset cursors, strict bounds (`limit <= 100`), allowlisted trend intervals (`minute`, `hour`, `day`), and environment attribution, and verify unit specs pass
- [x] 1.2 Implement `Sentrace::Mcp::Dispatcher` (`lib/sentrace/mcp/dispatcher.rb`) for environment discovery (`list_environments` without credential leakage) and `:local` environment dispatch/validation, and verify unit specs pass

## 2. MCP Server Tools, Read-Only Resources & Investigation Prompt

- [x] 2.1 Implement `Sentrace::Mcp::Server` (`lib/sentrace/mcp/server.rb`) wrapping the `mcp` gem (`MCP::Server`) to register all 8 tools (`list_environments`, `list_projects`, `list_issues`, `get_issue`, `update_issue_status`, `list_events`, `get_event`, `get_error_trends`), 5 `sentrace://` resources/templates, and the `investigate_issue` prompt (separating observed evidence from hypotheses), and verify JSON-RPC protocol specs pass

## 3. Standalone `stdio` Transport & Rake Task

- [x] 3.1 Implement `Sentrace::Mcp::StdioRunner` (`lib/sentrace/mcp/stdio_runner.rb`) and `bin/rails sentrace:mcp` (`lib/tasks/sentrace_mcp.rake`) with `stdout` log isolation, verify end-to-end `stdio` JSON-RPC round-trip specs (`spec/integration/mcp_stdio_spec.rb`), and document `bin/rails sentrace:mcp` usage in `README.md`

## Workflow follow-up

- Run `openspec validate --all --strict --no-interactive`, verify full RSpec + RuboCop suites, and archive `phase-3-mcp-local-server`.
- Propose `phase-4-environment-federation` next following `SPEC.md` §16.
