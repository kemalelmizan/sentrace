# Design: Production Integration Hardening (`v0.1.2`)

## Context

Enterprise deployment of `sentrace` `0.1.1` in a Rails 6.1 + React 17 + Webpack 4 + TypeScript 4.4 + Sidekiq 6.5 + Puma (`preload_app!`) application validated the core PostgreSQL schema, Sentry v7 envelope ingestion, native Ruby SDK, and ES2019 frontend bundles, while surfacing five concrete operational and ergonomic edge cases in global MCP host processes, off-VPN multi-environment configurations, same-origin Rails HTML/SPA DSN wiring, Rails boot safety, and host RSpec/SPA lifecycle management.

Per `openspec/config.yaml` and `SPEC.md`:
- **PostgreSQL & Storage Impact**: Zero database migrations, zero table/index modifications, and zero impact on `sentrace_events.event_data` (`jsonb`) bounds or B-tree index selectivity.
- **Layer Boundaries (`app/` vs `lib/sentrace/`)**: `app/models/sentrace/{project,project_key}.rb` remain thin persistence/credential models that notify pure domain services in `lib/sentrace/` (`FrontendDsnResolver`, `CaptureDispatcher`) on key lifecycle mutations; MCP transport (`lib/sentrace/mcp/`), frontend DSN resolution (`lib/sentrace/frontend_dsn_resolver.rb`), Rack middleware (`lib/sentrace/integrations/`), and test helpers (`lib/sentrace/test_helpers.rb`) reside strictly in `lib/sentrace/`.

## Goals / Non-Goals

**Goals:**
- Prevent any pre-boot or mid-session Ruby/native write to `stdout` (`fd 1`) from corrupting MCP `stdio` JSON-RPC framing, and make `bin/sentrace-mcp` work out-of-the-box from arbitrary working directories and minimal GUI `PATH`s.
- Bound `list_environments` wall-clock latency to `<= 2.5s` by default regardless of how many remote `:http` environments are offline or behind VPN DNS resolvers.
- Enable zero-SQL-after-warmup, non-raising, zero-env-var same-origin public DSN resolution for `<%= sentrace_meta_tags %>` and SPA config endpoints (`Sentrace.frontend_dsn`).
- Ensure partially configured `:http` environments never crash `rails db:migrate`, `assets:precompile`, `rspec`, or `rails console`.
- Suppress non-actionable Puma client-disconnect socket noise while populating middleware fallback culprits, provide a clean RSpec test isolation helper, and make `Sentrace.init()` idempotent in `packages/sentrace` (`0.1.2`).

**Non-Goals:**
- No transactions, spans, metrics, sessions, replays, logs, attachments, Redis dependencies, Devise coupling, or new database columns/indexes (`SPEC.md` Section 1.3).
- No custom native C extensions or external HTTP client gems (`Net::HTTP` stdlib only).

## Decisions

### 1. Dual-Layer `stdout` (`fd 1`) Isolation (`IsolatedStdioTransport` + `bin/sentrace-mcp`)
- **Finding**: Upstream `::MCP::Server::Transports::StdioTransport#send_response` (`mcp-1.10.0`) hardcodes `$stdout.puts(json_message)` and `$stdout.flush` rather than accepting an output `IO`. Simply reassigning `$stdout = $stderr` without overriding `send_response` would send JSON-RPC responses to `stderr`!
- **Design**:
  1. Define `Sentrace::Mcp::StdioRunner::IsolatedStdioTransport < ::MCP::Server::Transports::StdioTransport` accepting `output_io:` and overriding `send_response` to serialize and write/flush directly to `@output_io` (defaulting `@input` handling via custom line reading from `@input` as already implemented in `StdioRunner` or delegating `handle_json_request`). Wait — let's check how `StdioRunner` currently uses `StdioTransport`! Let's ensure `IsolatedStdioTransport` handles both custom `@input` and `@output_io` cleanly.
  2. When `isolate_stdout_logs: true`:
     - If `@output.equal?($stdout)` and `@output.equal?(STDOUT)` (the default CLI path), duplicate OS `fd 1` (`mcp_output = STDOUT.dup; mcp_output.sync = true`), redirect OS `fd 1` (`STDOUT.reopen(@err_output)` when `@err_output.is_a?(IO)`) and Ruby `$stdout = @err_output` so both `puts`/`print` AND native C/Ruby writes to `STDOUT` go to `stderr`, while `mcp_output` writes exclusively to the original MCP pipe. Restore `STDOUT.reopen(mcp_output)`, close `mcp_output`, and restore `$stdout` in `ensure`.
     - If `@output` is already a separate `IO` or `StringIO` (such as `mcp_stdout` passed by `bin/sentrace-mcp` or `StringIO` in specs), write JSON-RPC frames to `@output` while redirecting `$stdout = @err_output` for the duration of `run` (restoring `$stdout` in `ensure`).
  3. Generate `bin/sentrace-mcp` (`chmod 0755`) using `#!/usr/bin/env sh` so POSIX `/bin/sh` resolves `APP_ROOT`, `cd`s into it, prepends `$HOME/.rbenv/shims`, `$HOME/.local/share/mise/shims`, and `$HOME/.asdf/shims` if present on disk, and `exec`s `ruby -e '...' -- "$@"` (preserving `stdin` `fd 0` untouched for MCP JSON-RPC). Inside the inline Ruby bootstrap, duplicate `$stdout` (`mcp_stdout = $stdout.dup; mcp_stdout.sync = true`) and redirect `$stdout.reopen($stderr)` **before** `require_relative "config/boot"` and `require_relative "config/environment"`.

### 2. Concurrent `list_environments` + Monotonic Wall-Clock `RemoteHttpClient` Deadlines
- **Concurrency**: `EnvironmentRouter#list_environments` maps `@config.environments.values` onto concurrent `Thread.new` workers (matching `execute_federated`), wrapping `:local` status checks in `ActiveRecord::Base.connection_pool.with_connection` when more than one environment spawns threads, and joins results in original configuration order.
- **Wall-Clock Deadline**: `RemoteHttpClient` adds an optional `timeout:` keyword to `environment_status` and `post_json_rpc`. `perform_net_http_post` sets `http.max_retries = 0` (preventing Ruby 3.x `Net::HTTP` from silently doubling connect timeouts via automatic idempotent retries), `http.ssl_timeout = effective_timeout`, `http.open_timeout = effective_timeout`, `http.read_timeout = effective_timeout`, and wraps `http.start` in `Timeout.timeout(effective_timeout)` so blocking `getaddrinfo` DNS lookups, multi-A/AAAA record fallbacks, and stalled TLS handshakes abort strictly within `effective_timeout` and map `Timeout::Error` to `McpRemoteError(category: "timeout")`.
- **Ping Timeout & Unconfigured State**: `Configuration#remote_ping_timeout` defaults to `2.5` seconds (`POSITIVE_NUMERIC_ATTRIBUTES`). `EnvironmentRouter#environment_status` passes `timeout: [env_def.timeout, @config.remote_ping_timeout].min`. When an `:http` environment has blank `url` or blank `token`, `Configuration` allows boot without raising `ConfigurationError`, `environment_status` immediately returns `"unconfigured"` with zero network I/O, and `RemoteHttpClient#post_json_rpc` raises `McpRemoteError(category: "unconfigured")` if queried directly or via `"all"`.

### 3. `Sentrace::FrontendDsnResolver` & Bounded Thread-Safe Key Caching
- **Resolution Order**:
  1. If `config.frontend_dsn` is present and `project` was not explicitly overridden, parse via `Dsn.parse` and return `parsed.to_public_s(include_port: true)`.
  2. Otherwise resolve `target = project || config.project_slug || config.project_id`. Return `nil` if `target` is blank or `base_url` is blank.
  3. Look up `[project_id, public_key]` in a `Mutex`-guarded in-memory Hash keyed by normalized target (`["id", Integer]` or `["slug", String]`, bounded to `<= 128` entries to prevent unbounded memory growth if dynamic slugs are passed). On cache miss, query `Sentrace::Project` and its latest active `Sentrace::ProjectKey` (`active.order(created_at: :desc).pick(:public_key)`). Do **not** cache `nil` indefinitely when tables are unmigrated or before `sentrace:setup` runs — returning `nil` on missing/keyless projects avoids poisoning the cache if `Project.ensure!` runs in another process, while `clear_cache!` also clears positive entries on all local mutations (`Project.ensure!`, `Project.provision!`, `Project#rotate_key!`, `ProjectKey#revoke!`, model `after_commit`/`after_save`/`after_destroy`, and `CaptureDispatcher.clear_cache!`).
  4. Construct the base URL by combining `base_url` with the mounted `Sentrace::Engine` path (`resolve_engine_mount_path`) unless `base_url` already ends with that mount path, then format via `Dsn.format(base_url: ..., public_key: public_key, project_id: project_id)`.
  5. Rescue `Sentrace::Error`, `ActiveRecord::StatementInvalid`, `ActiveRecord::NoDatabaseError`, and `ActiveRecord::ConnectionNotEstablished`, returning `nil`.
- **Public API**:
  - `Sentrace.resolve_frontend_dsn(base_url:, project: nil)` -> `String | nil`
  - `Sentrace.frontend_dsn(base_url: nil, request: nil, project: nil)` -> extracts `base_url || request&.base_url` and delegates to `resolve_frontend_dsn`.
  - `ViewHelpers#sentrace_meta_tags` delegates directly to `Sentrace.frontend_dsn(base_url: base_url, request: req, project: project)`.

### 4. Middleware Fallback `culprit`, Puma Disconnect Filtering, & `Sentrace::TestHelpers`
- **Fallback `culprit`**: In `RackMiddleware#populate_controller_culprit`, when `action_dispatch.request.path_parameters` lacks `controller`/`action`, compute `"#{method} #{sanitized_path}"` (extracting the path component without query string from `env["PATH_INFO"]` or `SCRIPT_NAME + PATH_INFO`) so pre-routing middleware crashes produce a clean, non-nil culprit without leaking query parameters.
- **Disconnect Noise**: Add `"ActionController::Live::ClientDisconnected"` to `Configuration::DEFAULT_EXCLUDED_EXCEPTIONS`. In `RackMiddleware#excluded_exception?`, additionally ignore `IOError` whose message matches `/\bstream closed in another thread\b/i` **only when** `StacktraceBuilder` (or `in_app` backtrace inspection) finds zero `in_app` application frames — suppressing Puma reactor client-abort noise while still capturing genuine `IOError` / `Errno::ECONNRESET` / `Errno::EPIPE` raised by upstream HTTP/Redis/DB calls inside `app/` or `lib/`.
- **Test Isolation**: Implement `Configuration#initialize_copy` deep-duplicating mutable arrays/hashes (`@redact_fields`, `@allow_fields`, `@retain_user_fields`, `@cors_allowed_origins`, `@excluded_exceptions`, `@breadcrumbs_logger`, `@environments`). Expose `Sentrace.with_configuration(**overrides)` and `Sentrace::TestHelpers#with_sentrace_test_config(**overrides)` (which defaults `enabled: true, capture_dispatch: :inline` and isolates config, `CaptureDispatcher` + `FrontendDsnResolver` caches, `ExceptionDeduplicator`, and `Scope`).

### 5. Frontend `packages/sentrace` Idempotent `init()`, `isEnabled()`, & `lastEventId()` (`0.1.2`)
- **Non-Destructive Wrapper Deactivation**: In `packages/sentrace/src/browser.ts`, maintain a boolean `let active = true` inside `installBrowserInstrumentation`. When the returned teardown function runs:
  - Set `active = false` first so `wrappedFetch`, `XMLHttpRequest.prototype.open`/`send`, and `history.pushState`/`replaceState` immediately become zero-overhead pass-throughs to the underlying function **even if** third-party code wrapped `window.fetch` or `XMLHttpRequest` after `init()` (preventing restoration from clobbering third-party wrappers when `win.fetch !== wrappedFetch`, while cleanly restoring `win.fetch = nativeFetch` when `win.fetch === wrappedFetch`).
  - Remove `window` / `document` event listeners (`error`, `unhandledrejection`, `click`, `popstate`, `turbo:*`).
- **Lifecycle Semantics**:
  - `init(options)`: Tears down previous client/DOM instrumentation (`activeClient.disposeInstrumentation()`) while **preserving `globalScope`** (tags/user/breadcrumbs set before or between `init` calls, updating `maxBreadcrumbs` and seeding newly discovered `<meta name="sentrace-request-id">` if unset). Resets omitted options to clean `SentraceInitOptions` defaults so `init({ enabled: false })` followed by `init({ dsn })` enables the new client cleanly.
  - `isEnabled()`: Returns `Boolean(activeClient && activeClient.isEnabled())` (true iff initialized, `enabled !== false`, and `parsedDsn !== null`).
  - `lastEventId()`: Returns `lastCapturedEventId` (`string | undefined`), updated whenever `client.captureEvent` accepts and transmits an event, unchanged when an event is dropped by `enabled: false`, `sampleRate`, `ignoreErrors`, URL filters, or `beforeSend`, and reset to `undefined` on `close()` / `resetClient()`.
  - Maintain strict ES2019 syntax across TypeScript sources and emitted bundles (`0.1.2`).
