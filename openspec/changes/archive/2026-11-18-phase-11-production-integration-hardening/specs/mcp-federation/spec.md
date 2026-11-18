## MODIFIED Requirements

### Requirement: Per-environment timeouts and partial-failure isolation
Federation requests SHALL enforce each remote environment's timeout as a strict monotonic wall-clock deadline covering DNS, TCP (`max_retries = 0`), TLS (`ssl_timeout`), and HTTP I/O, SHALL cap `list_environments` `ping` probes to `[env.timeout, config.remote_ping_timeout].min` (default `2.5` seconds), and SHALL isolate unavailable, timed-out, unauthorized, or unconfigured (blank URL/token) environments with structured failure categories and zero leaked tokens.

#### Scenario: Timed-out staging environment does not block local and production results
- **GIVEN** `local` (`:local`), `staging` (`:http`, `timeout: 0.1` seconds, hanging), and `production` (`:http`, healthy)
- **WHEN** an MCP client calls `list_issues` with `environment: "all"`
- **THEN** the response completes promptly with `local` and `production` issues plus an explicit `errors` entry identifying `staging` with category `"timeout"` and zero leaked credentials

#### Scenario: Wall-clock deadline bounds slow DNS or TLS handshake in RemoteHttpClient
- **GIVEN** a remote `:http` environment configured with `timeout: 0.15` seconds whose underlying resolver or TLS handshake stalls for `2.0` seconds
- **WHEN** `RemoteHttpClient` executes `call_tool` or `environment_status`
- **THEN** the call aborts within the wall-clock deadline (`< 0.5` seconds) and reports category `"timeout"` instead of hanging until OS resolver expiration

#### Scenario: Blank URL or token on remote HTTP environment reports unconfigured without crashing
- **GIVEN** `local` (`:local`) and `staging` (`:http`, `url: nil`, `token: nil`) configured in `Sentrace.configuration`
- **WHEN** an MCP client calls `list_environments` and `list_issues` with `environment: "all"`
- **THEN** `list_environments` reports `staging` with `"status" => "unconfigured"` and `list_issues` returns `local` issues alongside an `errors` entry for `staging` with `"category" => "unconfigured"`
