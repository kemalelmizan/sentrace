# Proposal

## Why

Production integration of `sentrace` `0.1.1` into an enterprise Rails 6.1 + React 17 + Webpack 4 + TypeScript 4.4 + Sidekiq 6.5 + Puma (`preload_app!`) monolith surfaced five real-world friction points: `bin/rails sentrace:mcp` fails when spawned from global GUI IDE configs due to pre-boot `stdout` pollution, working-directory mismatches, and missing Ruby version-manager shims; `list_environments` probes remote `:http` environments sequentially without DNS/SSL wall-clock bounds (`~120s` off-VPN); same-origin `sentrace_meta_tags` requires manual `SENTRACE_FRONTEND_DSN` maintenance or uncached per-request SQL queries that can raise on unmigrated/keyless projects; uncommented `:http` environment blocks in `initializer.rb` crash Rails boot when env vars are unset; and host RSpec/SPA/Puma integrations need isolated test helpers, middleware fallback culprits, Puma client-disconnect noise suppression, and idempotent `Sentrace.init()` + `isEnabled()` / `lastEventId()` frontend helpers (`v0.1.2`).

## What Changes

- **Local `stdio` MCP Server Descriptor Isolation & `bin/sentrace-mcp` Binstub (`SPEC.md` Section 7.1)**:
  - Update `Sentrace::Mcp::StdioRunner` so when `isolate_stdout_logs: true`, JSON-RPC frames are written exclusively to an isolated output stream (`$stdout.dup` with `sync = true` when `output.equal?($stdout)`) while global `$stdout` (and `STDOUT` when bound to OS `fd 1`) is redirected to `err_output` (`$stderr`) for the duration of `run` and restored in `ensure`.
  - Update `rails generate sentrace:install` to create an executable `bin/sentrace-mcp` (`chmod 0755`) script that `cd`s to `APP_ROOT`, prepends user Ruby shim directories (`$HOME/.rbenv/shims`, `$HOME/.local/share/mise/shims`, `$HOME/.asdf/shims`) when present, duplicates `fd 1` for MCP output, and redirects `$stdout.reopen($stderr)` **before** loading `config/boot` and `config/environment`.
- **Concurrent, Wall-Clock Bounded `list_environments` Probing (`SPEC.md` Sections 7.3 & 7.4)**:
  - Probe all configured environments concurrently in `Sentrace::Mcp::EnvironmentRouter#list_environments` while preserving configured environment ordering and checking out pooled `ActiveRecord` connections safely for `:local` worker threads.
  - Enforce strict monotonic wall-clock deadlines (`Timeout.timeout` + `http.ssl_timeout = timeout` + `http.max_retries = 0`) in `Sentrace::Mcp::RemoteHttpClient#perform_net_http_post` and `post_json_rpc`, and add `config.remote_ping_timeout` (default `2.5` seconds) capping `environment_status` ping probes to `[env_def.timeout, config.remote_ping_timeout].min`.
- **Zero-Config Same-Origin `frontend_dsn` Auto-Resolution, Thread-Safe Caching, & SPA Helper (`SPEC.md` Sections 4.1 & 5.3)**:
  - Add `Sentrace::FrontendDsnResolver`, `Sentrace.resolve_frontend_dsn(base_url:, project: nil, ...)`, and `Sentrace.frontend_dsn(base_url: nil, request: nil, project: nil)` falling back automatically to `project || config.project_slug || config.project_id` when `config.frontend_dsn` is blank, while preserving explicit `config.frontend_dsn` precedence.
  - Cache `[project_id, public_key]` in memory behind a `Mutex` (zero SQL queries per HTML/API render after warmup) with automatic cache invalidation on `Project.ensure!`, `Project.provision!`, `Project#rotate_key!`, `ProjectKey#revoke!`, model save/destroy callbacks, and `CaptureDispatcher.clear_cache!`, and rescue `Sentrace::Error`, `ActiveRecord::StatementInvalid`, `ActiveRecord::NoDatabaseError`, and `ActiveRecord::ConnectionNotEstablished` to return `nil` / empty meta tags instead of raising `500` errors.
- **Install Generator, Boot-Safe `:http` Environments, & Bootstrapper Polish (`SPEC.md` Sections 6.3 & 7.3)**:
  - Allow `:http` environment entries in `Sentrace::Configuration` with blank `url` or `token` to pass boot validation without raising `ConfigurationError`, reporting `"unconfigured"` in `list_environments` and structured `"unconfigured"` `McpRemoteError` attribution on federated queries while preserving strict HTTPS validation whenever `url` is present.
  - Update `initializer.rb.tt` to default `config.enabled = ENV.fetch("SENTRACE_ENABLED", (!Rails.env.test?).to_s) == "true"` and prefill `config.project_slug`, modernize `InstallGenerator` post-install instructions (native `Sentrace` Ruby capture, `sentrace_meta_tags`, `./bin/sentrace-mcp`, optional legacy `Sentrace::SentryTransport`), and print `SENTRACE_FRONTEND_DSN` alongside clarified `SENTRY_DSN` notes in `Sentrace::Bootstrapper#run`.
- **Retention Contract Docs, Rack Fallback `culprit` & Disconnect Filtering, `TestHelpers`, & Frontend `init` Idempotency (`SPEC.md` Sections 4.4, 5.7, & 6)**:
  - Document `Sentrace::Retention::Cleaner.run!` and all `CleanupResult` attributes (`deleted_events_count`, `deleted_orphan_issues_count`, `event_batches`, `issue_batches`, `event_cutoff`, `orphan_issue_cutoff`) in `README.md`.
  - Fall back to `"#{method} #{sanitized_path}"` (without query string) in `RackMiddleware#populate_controller_culprit` when `action_dispatch.request.path_parameters` is absent, add `ActionController::Live::ClientDisconnected` to `DEFAULT_EXCLUDED_EXCEPTIONS`, and ignore pure Puma socket-layer `IOError` (`stream closed in another thread`) with zero `in_app` frames while preserving real upstream `IOError` / `Errno::ECONNRESET` / `Errno::EPIPE` capture.
  - Ship `Sentrace.with_configuration(**overrides) { ... }` and `Sentrace::TestHelpers` isolating configuration, caches, deduplicator state, and fiber scope per test example.
  - Export `isEnabled(): boolean` and `lastEventId(): string | undefined` in `packages/sentrace` (ES2019-clean across ESM, CJS, IIFE, and synced Rails engine assets), make repeated `Sentrace.init(...)` calls preserve `globalScope` while cleanly deactivating prior `error` / `unhandledrejection` / `fetch` / `XHR` / `history` / `Turbo` listeners without duplicate breadcrumbs or captures, and bump gem + npm version to `0.1.2`.
- **Explicit Out-of-Scope Boundaries (`SPEC.md` Section 1.3 & Section 5.2)**:
  - Strictly NO tables, columns, or persistence for transactions, spans, performance metrics, sessions, replays, logs, attachments, external object storage, alerting, or a web UI/dashboard; NO Redis or hard background-job adapter dependency; NO raw request bodies, SQL bind values, cookies, or unredacted secrets; and NO new PostgreSQL migrations or GIN indexes on `sentrace_events.event_data`.

## Capabilities

### New Capabilities

<!-- None: all improvements extend and harden existing Sentrace capabilities. -->

### Modified Capabilities
- `mcp-server`: Isolate `stdout` (`fd 1`) from non-JSON-RPC Ruby/C output inside `Sentrace::Mcp::StdioRunner` and provide the executable `bin/sentrace-mcp` binstub for working-directory and Ruby-shim-safe `stdio` execution (`specs/mcp-server/spec.md`).
- `mcp-federation`: Probe `list_environments` concurrently, enforce monotonic wall-clock + SSL timeouts and `remote_ping_timeout` (`2.5s`) in `RemoteHttpClient`, and report `"unconfigured"` cleanly when remote `:http` URL or token is blank (`specs/mcp-federation/spec.md`).
- `rails-frontend-integration`: Auto-resolve same-origin public DSNs from `config.project_slug` / `config.project_id` with thread-safe in-memory `[project_id, public_key]` caching, database/key error resilience in views, `Sentrace.frontend_dsn` / `Sentrace.resolve_frontend_dsn` helpers, and synced `0.1.2` engine JS bundles (`specs/rails-frontend-integration/spec.md`).
- `project-management`: Invalidate cached frontend DSN credentials on `Project.ensure!`, `Project.provision!`, `Project#rotate_key!`, and `ProjectKey#revoke!`, and emit `SENTRACE_FRONTEND_DSN` alongside clarified `SENTRY_DSN` output in `Bootstrapper#run` (`specs/project-management/spec.md`).
- `engine-configuration`: Add `remote_ping_timeout` (`2.5s`), allow blank-URL/token `:http` environments to pass boot validation, generate executable `bin/sentrace-mcp` and test-safe `initializer.rb.tt` (`!Rails.env.test?`), and modernize install instructions (`specs/engine-configuration/spec.md`).
- `ruby-capture-sdk`: Populate Rack fallback `culprit` (`"#{method} #{path}"` without query string) when `path_parameters` is absent, suppress non-app Puma `stream closed in another thread` socket disconnects and `ActionController::Live::ClientDisconnected`, and expose `Sentrace.with_configuration` + `Sentrace::TestHelpers` (`specs/ruby-capture-sdk/spec.md`).
- `event-retention`: Formalize and document the programmatic `Sentrace::Retention::Cleaner.run!` `CleanupResult` struct contract for direct scheduler workers (`specs/event-retention/spec.md`).
- `browser-sdk`: Add `isEnabled()` and `lastEventId()`, guarantee idempotent multi-call `Sentrace.init(...)` listener teardown and `globalScope` preservation even across interleaved `fetch`/`XHR` wrappers, and bump package outputs to `0.1.2` (`specs/browser-sdk/spec.md`).

## Impact

- **Ruby Engine & Models**: `lib/sentrace.rb`, `lib/sentrace/version.rb`, `lib/sentrace/configuration.rb`, `lib/sentrace/frontend_dsn_resolver.rb`, `lib/sentrace/view_helpers.rb`, `lib/sentrace/capture_dispatcher.rb`, `lib/sentrace/bootstrapper.rb`, `lib/sentrace/test_helpers.rb`, `lib/sentrace/integrations/rack_middleware.rb`, `lib/sentrace/mcp/{stdio_runner,environment_router,remote_http_client}.rb`, and `app/models/sentrace/{project,project_key}.rb`.
- **Generators & Templates**: `lib/generators/sentrace/install/install_generator.rb` and `lib/generators/sentrace/install/templates/{initializer.rb.tt,sentrace-mcp.tt}`.
- **Frontend SDK (`packages/sentrace`)**: `package.json`, `scripts/build.mjs`, `src/{dsn,browser,client,index}.ts`, rebuilt `dist/*`, `react/*`, and synced `app/assets/javascripts/sentrace*.js`.
- **Documentation & Tests**: `README.md`, `packages/sentrace/README.md`, RSpec unit/integration/generator specs (`spec/`), and Node test suite (`packages/sentrace/test/`).
- **Database & Dependencies**: Zero database migrations, zero schema changes, and zero new runtime dependencies.
