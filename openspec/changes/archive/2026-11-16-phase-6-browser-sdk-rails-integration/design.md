# Design

## Context

Sentrace currently ingests backend Ruby exceptions (`sentry-ruby`) into PostgreSQL (`sentrace_projects`, `sentrace_project_keys`, `sentrace_issues`, `sentrace_events`, `sentrace_mcp_tokens`) and exposes federated MCP tools across `stdio` and Streamable HTTP. `packages/sentrace` was initialized as a stub (`0.0.1`) and not yet published to npm. See `proposal.md` for motivation and scope boundaries.

Key constraints shaping this design:
- **Zero-dependency npm package**: `packages/sentrace` (`0.1.0`) must have zero runtime dependencies (`dependencies: {}`), compile from clean TypeScript (`src/*.ts`) using Node's native `module.stripTypeScriptTypes` bundler script (`scripts/build.mjs`), and emit ESM (`dist/index.mjs`), CommonJS (`dist/index.cjs`), TypeScript declarations (`dist/index.d.ts`), and an IIFE browser bundle (`dist/sentrace.browser.js`).
- **Host Rails independence**: `Sentrace::Engine` runs inside both API-only (`config.api_only = true`, without `action_view/railtie` or asset gems) and full-stack Rails applications (`ActionView`, Propshaft/Sprockets, Importmap, Hotwire Turbo + Stimulus).
- **Storage & privacy discipline**: Zero new PostgreSQL tables, zero raw envelope persistence, zero GIN indexes over `event_data`, pre-parse size limits (`max_envelope_size`), and strict PII redaction before both wire transmission (client query-string scrubbing) and DB persistence (`Sanitizer`).

## Goals / Non-Goals

**Goals:**
- Provide a drop-in `@sentry/browser`-compatible TypeScript SDK (`sentrace` `0.1.0`) speaking standard Sentry v7 Envelopes while ensuring official `@sentry/browser` envelopes also ingest cleanly into `Sentrace::Engine`.
- Deliver zero-boilerplate Rails integration via `sentrace_meta_tags`, engine-bundled JS assets, Hotwire Turbo/Stimulus instrumentation, and cross-stack `X-Request-Id` (`request_id`) correlation in MCP.
- Guarantee stable cross-environment browser issue fingerprints across origins and hashed Propshaft/Sprockets/Vite/Webpack JS bundles.

**Non-Goals:**
- No browser transactions/spans, Web Vitals, session replay, source-map symbolication storage, attachments, or dashboard UI.
- No new database columns or migrations.

## Decisions

### 1. Zero-Dependency TypeScript Architecture & Native Node Build (`packages/sentrace/`)
- **Choice**: Author modular TypeScript under `packages/sentrace/src/` (`types.ts`, `dsn.ts`, `stacktrace.ts`, `scope.ts`, `envelope.ts`, `transport.ts`, `browser.ts`, `rails.ts`, `client.ts`, `index.ts`) and build single-file ESM, CommonJS, IIFE (`window.Sentrace`), and `.d.ts` outputs using a deterministic `scripts/build.mjs` powered by Node's built-in `module.stripTypeScriptTypes`, syncing ESM + IIFE outputs into `app/assets/javascripts/`.
- **Rationale**: Zero runtime and zero supply-chain dependencies keep the browser bundle tiny (< 6 KB gzipped), offline-buildable, auditable, and compatible with Node ESM/CJS, Vite/esbuild/Webpack, Rails `importmap-rails`, and `<script>` tags.
- **Alternatives considered**:
  - *Wrapping `@sentry/browser`*: Adds ~30–80 KB of unused tracing/replay/session machinery and external dependency churn.

### 2. Sentry v7 Wire Protocol & Browser Transport
- **Choice**: Parse Sentrace/Sentry DSNs (`http(s)://<public_key>@<host>/<prefix>/<project_id>`) into `/<prefix>/api/<project_id>/envelope?sentry_key=<public_key>&sentry_version=7&sentry_client=sentrace-js/0.1.0`. Send 3-line newline-delimited Sentry v7 envelopes via `fetch(url, { method: "POST", body, keepalive: true, headers: { "Content-Type": "text/plain;charset=UTF-8" } })`, falling back to `navigator.sendBeacon(url, body)` during unload (`visibilitychange: hidden` / `pagehide`) or when `fetch` is unavailable.
- **Rationale**: `text/plain;charset=UTF-8` with `?sentry_key=...` avoids unnecessary CORS preflight round-trips on simple cross-origin requests while remaining 100% compatible with `IngestionController#extract_credentials` and `@sentry/browser`'s wire format.
- **Engine CORS support**: For cross-origin SPAs (including `@sentry/browser` configurations that send `X-Sentry-Auth` or `Content-Encoding: gzip`), `Sentrace::Engine` routes `OPTIONS /api/:project_id/envelope` to `IngestionController#options` and sets `Access-Control-Allow-Origin` (`*` or exact matched origin + `Vary: Origin`), `Access-Control-Allow-Methods: POST, OPTIONS`, `Access-Control-Allow-Headers: Content-Type, Content-Encoding, X-Sentry-Auth, Authorization`, and `Access-Control-Max-Age: 86400` only when `request.headers["Origin"]` matches `Sentrace.configuration.cors_allowed_origins`.

### 3. Multi-Engine Stack Parsing & Asset-Digest Fingerprint Normalization
- **Choice**:
  - Client `stacktrace.ts` parses V8/Chromium (`at fn (file:line:col)` / `at file:line:col`), SpiderMonkey/Firefox (`fn@file:line:col`), and Safari/JavaScriptCore (`fn@file:line:col` / `global code@file:line:col`), reversing frames into Sentry's oldest-to-newest order and marking `node_modules`, browser extensions (`chrome-extension://`, `moz-extension://`, `safari-extension://`), and CDN vendor scripts `in_app: false`.
  - Backend `Sentrace::Ingestion::EventNormalizer` (`lib/sentrace/ingestion/event_normalizer.rb`) preserves integer `colno` alongside `lineno` (using `.compact` so Ruby frames without `colno` incur zero extra JSONB bytes) and folds top-level `extra` into `contexts["extra"]` within existing `max_context_entries` (`16`) and `max_context_bytes` (`8 KB`) bounds.
  - Backend `Sentrace::Issues::Fingerprint` (`lib/sentrace/issues/fingerprint.rb`) strips URL schemes/hosts (`http://`, `https://`, `webpack-internal:///`), query strings, fragments, and asset content-digest suffixes (`[-.][0-9a-f]{8,64}` before `.js`/`.mjs`/`.cjs`/`.jsx`/`.ts`/`.tsx`/`.map`), and appends `:col:<colno>` only when `function` is anonymous and `colno` is present.
- **Rationale**: Keeps `sentrace_issues.fingerprint` (64-char SHA-256) identical across `staging.example.com` and `app.example.com` and across Rails Propshaft/Sprockets/Vite deploys without source-map storage.

### 4. Rails Layer vs Pure Domain Boundaries & Cross-Stack `request_id` Correlation
- **Choice**:
  - **Pure Ruby domain (`lib/sentrace/`)**:
    - `Sentrace::ViewHelpers` (`lib/sentrace/view_helpers.rb`): Pure helper module building escaped `<meta name="sentrace-*">` tags and stripping any secret component from `Dsn.parse` so secret keys can never leak into HTML.
    - `EventNormalizer` extracts safe `X-Request-Id` (`/\A[A-Za-z0-9._:-]{1,128}\z/`) from `raw_request["headers"]` into `tags["request_id"]` before `Sanitizer` discards raw headers.
    - `Mcp::LocalBackend` and `Mcp::Server` add optional `platform` (`sentrace_events.platform = ?`) and `request_id` (`sentrace_events.event_data -> 'tags' ->> 'request_id' = ?`) filters to `list_events` and `list_issues`, leveraging existing `(project_id, occurred_at DESC)` and `(project_id, status, last_seen_at DESC)` B-tree indexes without adding GIN indexes.
  - **Rails integration layer (`lib/sentrace/engine.rb`, `app/controllers/sentrace/ingestion_controller.rb`, `app/assets/javascripts/`)**:
    - `ActiveSupport.on_load(:action_view) { include Sentrace::ViewHelpers }` registers helpers lazily only when `ActionView` is present.
    - Browser `rails.ts` auto-reads `<meta name="sentrace-*">` on `init()`, refreshes `request_id` on `turbo:load`, captures `turbo:fetch-request-error` and `turbo:frame-missing` events, extracts `X-Request-Id` from `fetch`/`XHR` responses into breadcrumbs and error tags, and provides `registerStimulusErrorHandler(application)`.

## Risks / Trade-offs

- **Minified anonymous JS function names** -> Preserving `lineno` + `colno` in `event_data` and disambiguating anonymous frames via `:line:<lineno>:col:<colno>` prevents unrelated minified anonymous callbacks on line 1 from colliding into one issue while named functions remain stable across minor edits.
- **JSONB `request_id` filter selectivity without a GIN index** -> Queries in `LocalBackend` combine `project_id` and `occurred_at` window B-tree indexes with `MAX_LIMIT = 100`, keeping single-request correlation sub-millisecond at target scale (`1k–100k` events/day) without write amplification from a JSONB GIN index.
- **Public DSN exposure in browser HTML** -> By design in Sentry's model, browser DSNs carry only `public_key` (write-only event ingestion bounded by `max_envelope_size`, never read/MCP access). `sentrace_meta_tags` additionally strips any `secret_key` if a user accidentally passes a secret-bearing DSN.
