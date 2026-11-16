# Tasks

## 1. Rails Engine Configuration, CORS Ingestion, and Browser Normalization

- [x] 1.1 Add `frontend_dsn`, `release`, and `cors_allowed_origins` to `Sentrace::Configuration` with validation and update `sentrace:install` generator instructions, verified with `bundle exec rspec spec/lib/sentrace/configuration_spec.rb spec/generators/install_generator_spec.rb`
- [x] 1.2 Add `OPTIONS /api/:project_id/envelope` preflight handling and origin-validated CORS headers on `Sentrace::IngestionController`, verified with `bundle exec rspec spec/requests/ingestion_spec.rb`
- [x] 1.3 Preserve integer stack frame `colno`, fold top-level `extra` into bounded `contexts["extra"]`, and extract safe `X-Request-Id` headers into `tags["request_id"]` in `EventNormalizer`, verified with `bundle exec rspec spec/lib/sentrace/ingestion/event_normalizer_spec.rb`
- [x] 1.4 Normalize browser URLs (stripping origins, query strings, and fragments), strip JS/TS asset content-digest suffixes, and disambiguate anonymous frames with `colno` in `Issues::Fingerprint`, verified with `bundle exec rspec spec/lib/sentrace/issues/fingerprint_spec.rb`

## 2. Rails View Helpers and Cross-Stack MCP Correlation

- [x] 2.1 Implement `Sentrace::ViewHelpers#sentrace_meta_tags` (lazy `ActiveSupport.on_load(:action_view)` registration and public-only DSN secret stripping), verified with `bundle exec rspec spec/lib/sentrace/view_helpers_spec.rb`
- [x] 2.2 Extend `Sentrace::Mcp::LocalBackend` and `Sentrace::Mcp::Server` with `platform` and `request_id` filtering on `list_issues` and `list_events` plus `request_id` summary attribution, verified with `bundle exec rspec spec/lib/sentrace/mcp/server_spec.rb`

## 3. Zero-Dependency `@sentry/browser`-Compatible TypeScript SDK (`packages/sentrace`)

- [x] 3.1 Implement TypeScript core modules (`types.ts`, `dsn.ts`, `stacktrace.ts`, `scope.ts`, `envelope.ts`, `transport.ts`) covering DSN parsing, V8/Firefox/Safari stack parsing, `Scope`/`withScope`, Sentry v7 envelope serialization, `fetch`/`sendBeacon` transport, and URL query-parameter scrubbing, verified with `node --test packages/sentrace/test/*.test.mjs`
- [x] 3.2 Implement browser global instrumentation (`browser.ts`), Rails `<meta>` auto-discovery + Hotwire Turbo / Stimulus hooks + `X-Request-Id` extraction (`rails.ts`), and top-level `@sentry/browser`-compatible client API (`client.ts`, `index.ts`), verified with `node --test packages/sentrace/test/*.test.mjs`
- [x] 3.3 Build `0.1.0` ESM (`dist/index.mjs`), CommonJS (`dist/index.cjs`), TypeScript declarations (`dist/index.d.ts`), and browser IIFE (`dist/sentrace.browser.js`) bundles via `scripts/build.mjs`, sync `app/assets/javascripts/sentrace*.js`, and update `packages/sentrace/README.md` and root `README.md`, verified with `npm --prefix packages/sentrace run build && npm --prefix packages/sentrace test && npm pack --dry-run ./packages/sentrace`

## 4. End-to-End Browser + Rails + MCP Integration Verification

- [x] 4.1 Add end-to-end integration spec generating real envelopes from `packages/sentrace` and `@sentry/browser`-compatible payloads, ingesting them alongside a backend Rails `X-Request-Id` error into `Sentrace::Engine`, and querying both via MCP `list_events(request_id: ...)` and `list_issues(platform: "javascript")`, verified with `bundle exec rspec spec/integration/browser_sdk_integration_spec.rb && bundle exec rubocop`

## Workflow follow-up

- Sync delta specs and archive `phase-6-browser-sdk-rails-integration` after full `rspec`, `rubocop`, `npm test`, and `openspec validate --all --strict --no-interactive` verification.
- Publish `sentrace@0.1.0` to npm via `npm publish ./packages/sentrace --access public`.
