# Tasks

## 1. Local `stdio` MCP Server Isolation & `bin/sentrace-mcp` Binstub

- [x] 1.1 Implement `IsolatedStdioTransport` and `fd 1` / `$stdout` / `STDOUT` descriptor isolation (with `ensure` restoration) in `lib/sentrace/mcp/stdio_runner.rb`, verifying with RSpec in `spec/integration/mcp_stdio_spec.rb` that mid-session `puts` and `STDOUT.puts` route to `stderr` while `stdout` emits uncorrupted JSON-RPC frames
- [x] 1.2 Add executable `bin/sentrace-mcp` (`chmod 0755`) template (`lib/generators/sentrace/install/templates/sentrace-mcp.tt`) and `InstallGenerator` wiring (`lib/generators/sentrace/install/install_generator.rb`) with `APP_ROOT` `cd`, Ruby shim `PATH` prepending, and pre-boot `fd 1` redirection, verifying with subprocess execution from `/tmp` in `spec/integration/mcp_stdio_spec.rb` and generator assertions in `spec/generators/sentrace/install_generator_spec.rb`
- [x] 1.3 Update MCP `stdio` configuration examples in `README.md` to recommend `/absolute/path/to/app/bin/sentrace-mcp` (global IDE configs) and `./bin/sentrace-mcp` (workspace `.mcp.json`), verifying documented paths match the generated binstub

## 2. Concurrent, Wall-Clock Bounded `list_environments` & Boot-Safe `:http` Configuration

- [x] 2.1 Add `remote_ping_timeout` (default `2.5` seconds), `Configuration#initialize_copy`, and boot-safe blank-`url` / blank-`token` `:http` validation (preserving strict HTTPS enforcement when `url` is present) in `lib/sentrace/configuration.rb`, verifying with RSpec in `spec/lib/sentrace/configuration_spec.rb`
- [x] 2.2 Enforce `http.max_retries = 0`, `http.ssl_timeout = timeout`, monotonic wall-clock `Timeout.timeout` deadlines, `timeout:` overrides, and `"unconfigured"` status/error handling in `lib/sentrace/mcp/remote_http_client.rb`, verifying slow DNS/TLS timeout bounds and `"unconfigured"` handling in `spec/lib/sentrace/mcp/remote_http_client_spec.rb`
- [x] 2.3 Implement concurrent thread probing (preserving configured order, pooling `:local` ActiveRecord connections safely, and applying `[env_def.timeout, config.remote_ping_timeout].min`) in `lib/sentrace/mcp/environment_router.rb`, verifying in `spec/integration/mcp_federation_spec.rb` and `spec/lib/sentrace/mcp/dispatcher_spec.rb` that 3 stalled remote environments complete `list_environments` concurrently within a single ping timeout window

## 3. Zero-Config `frontend_dsn` Auto-Resolution, Caching, Generator, & Bootstrapper Polish

- [x] 3.1 Implement `Sentrace::FrontendDsnResolver` (`lib/sentrace/frontend_dsn_resolver.rb`), `Sentrace.resolve_frontend_dsn` / `Sentrace.frontend_dsn` (`lib/sentrace.rb`), `ViewHelpers#sentrace_meta_tags` delegation (`lib/sentrace/view_helpers.rb`), and cache invalidation hooks (`app/models/sentrace/project.rb`, `app/models/sentrace/project_key.rb`, `lib/sentrace/capture_dispatcher.rb`), verifying zero-SQL-after-warmup auto-resolution, key-rotation invalidation, and keyless/unmigrated resilience in `spec/lib/sentrace/view_helpers_spec.rb`
- [x] 3.2 Update `initializer.rb.tt` (`!Rails.env.test?` default `enabled`, prefilled `project_slug`), `InstallGenerator#display_sdk_instructions`, `Sentrace::Bootstrapper#run` (`SENTRACE_FRONTEND_DSN` + clarified `SENTRY_DSN`), and `README.md` zero-config frontend / `Sentrace.frontend_dsn` documentation, verifying in `spec/generators/sentrace/install_generator_spec.rb` and `spec/tasks/sentrace_bootstrap_rake_spec.rb`

## 4. Retention Contract Docs, Rack Fallback `culprit` & Disconnect Filtering, & `Sentrace::TestHelpers`

- [x] 4.1 Add fallback `"#{method} #{sanitized_path}"` `culprit` (without query string) when `path_parameters` is absent, add `ActionController::Live::ClientDisconnected` to `DEFAULT_EXCLUDED_EXCEPTIONS`, and suppress non-`in_app` Puma `stream closed in another thread` `IOError` disconnects in `lib/sentrace/integrations/rack_middleware.rb` and `lib/sentrace/configuration.rb`, verifying in `spec/integration/ruby_integrations_spec.rb` and documenting Puma disconnect / `before_send` behavior in `README.md`
- [x] 4.2 Implement `Sentrace.with_configuration(**overrides)` (`lib/sentrace.rb`) and `Sentrace::TestHelpers` (`lib/sentrace/test_helpers.rb`) isolating config, caches, deduplicator, and scope per example, verifying in `spec/lib/sentrace/ruby_sdk_spec.rb` and documenting RSpec usage alongside the `Sentrace::Retention::Cleaner.run!` `CleanupResult` struct reference in `README.md` (`spec/lib/sentrace/retention/cleaner_spec.rb`)

## 5. Frontend `packages/sentrace` `isEnabled()`, `lastEventId()`, Idempotent `init()`, & `0.1.2` Bump

- [x] 5.1 Implement `isEnabled(): boolean`, `lastEventId(): string | undefined`, and non-destructive multi-call `Sentrace.init(...)` listener/wrapper deactivation (preserving `globalScope` and surviving third-party `fetch`/`XHR` wrappers) in `packages/sentrace/src/{browser,client,index,dsn}.ts` and `packages/sentrace/scripts/build.mjs`, bump `packages/sentrace/package.json` and `lib/sentrace/version.rb` (+ lockfiles) to `0.1.2`, rebuild bundles (`rtk npm --prefix packages/sentrace run build`), update `README.md` / `packages/sentrace/README.md`, and verify with `rtk npm --prefix packages/sentrace test`

## 6. Cross-Stack Matrix & Lint Verification

- [x] 6.1 Run full Rails 8.1 RSpec (`rtk bundle exec rspec`), Rails 6.1 / Rack 2.2 RSpec (`BUNDLE_GEMFILE=gemfiles/rails_6_1.gemfile rtk bundle exec rspec`), RuboCop (`rtk bundle exec rubocop`), Node package dry-run (`rtk npm pack --dry-run ./packages/sentrace`), and OpenSpec change validation (`rtk openspec validate --changes --strict --no-interactive`), verifying zero failures and zero offenses

## Workflow follow-up

- Sync delta specs from `openspec/changes/phase-11-production-integration-hardening/specs/` into `openspec/specs/`.
- Archive `phase-11-production-integration-hardening` into `openspec/changes/archive/` and verify `rtk openspec validate --all --strict --no-interactive`.
