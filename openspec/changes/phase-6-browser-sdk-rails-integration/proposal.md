# Proposal

## Why

Sentrace (`SPEC.md` §1–§4, §6, §11) already captures backend Ruby/Rails errors via `sentry-ruby` and exposes grouped issues and events across federated environments via MCP, while full-stack Rails applications and SPAs also experience client-side JavaScript, Hotwire Turbo, Stimulus, and `fetch` failures that coding agents need to correlate with backend Rails requests. Publishing `sentrace` `0.1.0` to npm as a zero-dependency, `@sentry/browser`-compatible TypeScript SDK with native Rails `<meta>` auto-discovery, Hotwire hooks, CORS support, JS asset-digest fingerprint normalization, and `request_id` correlation unifies frontend and backend error tracking inside a single self-hosted Sentrace deployment.

## What Changes

- **Zero-dependency `@sentry/browser`-compatible TypeScript SDK (`packages/sentrace` v`0.1.0`)**:
  - Implement top-level `@sentry/browser`-compatible API (`init`, `captureException`, `captureMessage`, `captureEvent`, `addBreadcrumb`, `setTag`, `setTags`, `setUser`, `setContext`, `setExtra`, `withScope`, `getCurrentScope`, `getClient`, `isInitialized`, `flush`, `close`) with `beforeSend`, `sampleRate`, `ignoreErrors`, `denyUrls`, `allowUrls`, and `maxBreadcrumbs`.
  - Parse V8/Chromium, SpiderMonkey/Firefox, and JavaScriptCore/Safari `Error.stack` traces into Sentry v7 stack frames (`filename`, `function`, `lineno`, `colno`, `in_app`) ordered oldest-to-newest.
  - Instrument browser `window` `error` and `unhandledrejection` listeners, UI click and History API navigation breadcrumbs, and `fetch` / `XMLHttpRequest` breadcrumbs with automatic `X-Request-Id` correlation on failed HTTP responses.
  - Serialize and transmit standard Sentry v7 Envelopes over `fetch(..., { keepalive: true })` (`Content-Type: text/plain;charset=UTF-8`) with `navigator.sendBeacon` fallback and client-side privacy scrubbing of sensitive query parameters and tokens.
  - Build dual ESM (`dist/index.mjs`), CommonJS (`dist/index.cjs`), TypeScript declarations (`dist/index.d.ts`), and browser IIFE global bundle (`dist/sentrace.browser.js` exported as `sentrace/browser`).
- **Cohesive Rails + Hotwire + MCP integration**:
  - Add `Sentrace::ViewHelpers#sentrace_meta_tags` (lazily registered via `ActiveSupport.on_load(:action_view)` so API-only Rails apps never load `ActionView`) rendering `<meta name="sentrace-dsn">`, `sentrace-environment`, `sentrace-release`, and `sentrace-request-id` (`request.request_id`), while stripping any accidental DSN secret key before rendering HTML.
  - Add automatic `<meta name="sentrace-*">` discovery in `Sentrace.init()`, Hotwire Turbo event listeners (`turbo:load`, `turbo:visit`, `turbo:fetch-request-error`, `turbo:frame-missing`), and `registerStimulusErrorHandler(application)` for Stimulus controllers.
  - Ship synced ESM (`app/assets/javascripts/sentrace.js`) and browser global (`app/assets/javascripts/sentrace.browser.js`) bundles inside the `sentrace` Rails engine for offline Importmap/Propshaft/Sprockets delivery without requiring any host asset pipeline gem.
  - Add Engine CORS preflight (`OPTIONS /api/:project_id/envelope`) and `Access-Control-Allow-*` response headers controlled by `config.cors_allowed_origins` for cross-origin SPAs.
  - Preserve integer `colno` on normalized stack frames, fold Sentry top-level `extra` into bounded `contexts["extra"]`, extract safe `X-Request-Id` headers into `tags["request_id"]`, normalize browser URLs and hashed JS asset filenames (`application-a1b2c3d4.js` -> `assets/application.js`) in `Issues::Fingerprint`, and add `platform` and `request_id` filters to MCP `list_issues` and `list_events`.
- **Explicitly Out of Scope (`SPEC.md` §3.2)**:
  - No browser performance tracing, transactions, spans, Web Vitals, session replay (`rrweb`), user session health metrics, source-map upload/symbolication object storage, attachments, logs, alerting, or web UI/dashboard.
  - No new PostgreSQL tables, no raw envelope storage, and no unbenchmarked GIN indexes over `sentrace_events.event_data`.

## Capabilities

### New Capabilities
- `browser-sdk`: Zero-dependency `@sentry/browser`-compatible TypeScript SDK (`packages/sentrace`) with Sentry v7 envelope transport, cross-browser stack parsing, scope/breadcrumb management, global browser instrumentation, and ESM/CJS/IIFE/types package outputs.
- `rails-frontend-integration`: Cohesive Rails view helpers (`sentrace_meta_tags`), engine-bundled JS assets, Hotwire Turbo and Stimulus error/breadcrumb hooks, and frontend-to-backend `request_id` correlation.

### Modified Capabilities
- `engine-configuration`: Add `cors_allowed_origins`, `frontend_dsn`, and `release` settings to `Sentrace::Configuration` and update `sentrace:install` frontend setup instructions.
- `sentry-ingestion`: Support `OPTIONS /api/:project_id/envelope` CORS preflight and response headers for configured origins, preserve frame `colno`, fold top-level `extra` into bounded `contexts["extra"]`, extract safe `X-Request-Id` headers into `tags["request_id"]`, and verify `@sentry/browser` envelope compatibility.
- `issue-grouping`: Normalize browser URLs and strip content-digest hashes from bundled JS/TS asset filenames (with anonymous frame `colno` disambiguation) during SHA-256 fingerprint computation.
- `mcp-server`: Add `platform` and `request_id` filtering on `list_issues` and `list_events` plus `request_id` attribution on serialized event summaries for cross-stack investigation.

## Impact

- **NPM Package (`packages/sentrace/`)**: New TypeScript source (`src/*.ts`), zero-dependency build script (`scripts/build.mjs`), dual ESM/CJS/IIFE/`.d.ts` artifacts (`dist/*`), comprehensive `node --test` suite (`test/*.test.mjs`), and `package.json` bumped to `0.1.0` for npm publication.
- **Rails Engine (`app/`, `config/`, `lib/`)**: Updates to `config/routes.rb`, `app/controllers/sentrace/ingestion_controller.rb`, `lib/sentrace/{configuration,engine,view_helpers}.rb`, `lib/sentrace/ingestion/event_normalizer.rb`, `lib/sentrace/issues/fingerprint.rb`, `lib/sentrace/mcp/{local_backend,server}.rb`, `lib/generators/sentrace/install/install_generator.rb`, and synced `app/assets/javascripts/sentrace*.js`.
- **Database Schema**: Zero schema migrations required; leverages existing `sentrace_events.platform` column and bounded `sentrace_events.event_data` (`jsonb`).
