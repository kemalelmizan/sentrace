## MODIFIED Requirements

### Requirement: Standalone local stdio MCP server execution
Sentrace SHALL expose an executable `bin/sentrace-mcp` (`0755`) binstub and `sentrace:mcp` task booting a `stdio` JSON-RPC MCP server without a web server. `StdioRunner` MUST write JSON-RPC frames to a dedicated stream and redirect `$stdout`/`STDOUT` to `stderr` during `run` (restoring in `ensure`); `bin/sentrace-mcp` MUST `cd` to `Rails.root`, prepend user Ruby shims to `PATH`, and redirect `fd 1` to `stderr` BEFORE booting Rails.

#### Scenario: MCP client initializes and discovers server capabilities over stdio
- **WHEN** an MCP client connects to the `sentrace:mcp` `stdio` server and sends `initialize`, `tools/list`, `resources/list`, `resources/templates/list`, and `prompts/list`
- **THEN** the server responds with valid JSON-RPC frames listing all Sentrace tools, static resources, resource templates, and the `investigate_issue` prompt

#### Scenario: Stray puts during mid-session tool execution do not corrupt MCP stdout frames
- **GIVEN** a running `Sentrace::Mcp::StdioRunner` with `isolate_stdout_logs: true`
- **WHEN** application or model code executes `puts "noisy boot or autoload log"` and `STDOUT.puts "native stdout noise"` while handling an MCP `tools/call` request
- **THEN** the MCP output stream receives only valid newline-delimited JSON-RPC frames, the stray text is routed to `err_output` (`$stderr`), and `$stdout` / `STDOUT` are cleanly restored after `run` completes

#### Scenario: Launching generated bin/sentrace-mcp from outside Rails.root isolates pre-boot stdout noise
- **GIVEN** a host Rails initializer or boot file that writes non-JSON text via `puts` during `config/environment` load
- **WHEN** an external MCP host spawns `/absolute/path/to/app/bin/sentrace-mcp` with working directory `/tmp` and sends `initialize` and `tools/list` over `stdin`
- **THEN** `bin/sentrace-mcp` switches to the application root, routes pre-boot `puts` output to `stderr`, and emits clean, parseable JSON-RPC responses on `stdout`

### Requirement: Environment and project discovery tools
The MCP server SHALL expose `list_environments` and `list_projects` tools returning configured deployment environments (probed concurrently across all configured environments in configuration order, reporting connection status including `"unconfigured"` when remote URL or token is blank, and never exposing secret tokens) and registered projects with environment attribution.

#### Scenario: Discovering local environment and projects without leaking secrets
- **GIVEN** configured `local` and `staging` (`token: "secret-tok"`) environments and a provisioned project `shop-api`
- **WHEN** a client calls `list_environments` and `list_projects`
- **THEN** `list_environments` returns environment names, transport types, and connectivity status without `"secret-tok"`, and `list_projects` returns `shop-api` attributed to `"local"`

#### Scenario: Probing multiple unreachable remote environments concurrently within ping timeout
- **GIVEN** `local` (`:local`) plus three unreachable `:http` environments (`staging`, `pre_prod`, `production`) and `remote_ping_timeout = 0.25` seconds
- **WHEN** a client calls `list_environments`
- **THEN** all environments are probed concurrently in threads, the response preserves `[local, staging, pre_prod, production]` order, and total wall-clock execution completes well below sequential `3 * 0.25` seconds
