# Proposal

## Why

Enterprise Ruby on Rails monoliths running `@rails/webpacker 5.4` (`webpack 4.46.0` / Acorn 6 with `ecmaVersion: 2019`), `React 17`, and `TypeScript 4.4` (`"moduleResolution": "node"`) parse `.mjs` files in `node_modules` without `babel-loader` and ignore `package.json` `"exports"`. Currently, `packages/sentrace` emits ES2020–ES2022 tokens (`?.`, `??`, bare `catch {}`, and ES2022 class field declarations) that crash Webpack 4 at compile time, lacks a drop-in React `<ErrorBoundary>` (`sentrace/react`), and calls `xhr.getResponseHeader("x-request-id")` without guarding against aborted or cross-origin `XMLHttpRequest` exceptions.

## What Changes

- **ES2018 / ES2019 Syntax Ceiling Across All Emitted Bundles (`packages/sentrace`)**:
  - Update `packages/sentrace/src/*.ts` and `packages/sentrace/scripts/build.mjs` so all emitted bundles (`dist/*.mjs`, `dist/*.cjs`, `dist/*.js`, `react/*.js`, `react/*.mjs`, and synced `app/assets/javascripts/sentrace*.js`) contain zero ES2020+ syntax tokens (`?.`, `??`, `??=`, `||=`, `&&=`, ES2022 class field declarations, private `#fields`, or bare `catch {}`), while retaining zero runtime npm dependencies.
  - Add automated bundle verification tests in `packages/sentrace/test/` asserting zero ES2020+ syntax tokens across every emitted bundle.
- **React `<ErrorBoundary>` & `withErrorBoundary` (`sentrace/react`) with Dual Modern + Legacy Resolution**:
  - Add `ErrorBoundary` and `withErrorBoundary` supporting `react >= 16.8.0` as an optional `peerDependency` only (`"peerDependenciesMeta": { "react": { "optional": true } }`, zero runtime `"dependencies"`).
  - Accept `fallback` as a React function or class component (`fallback={FallbackComponent}` — drop-in compatible with `@sentry/react`), a React element (`fallback={<div />}`), or a render function `({ error, componentStack, eventId, resetError }) => ReactNode`, along with `onError`, `onReset`, and `beforeCapture` hooks.
  - Capture unhandled React render/lifecycle errors with `handled: false`, `mechanism: { type: "react.error_boundary", handled: false }`, and `contexts: { react: { componentStack } }`.
  - Expose `sentrace/react` via both `"exports": { "./react": ... }` and a published top-level `react/` directory (`react/package.json`, `react/index.js`, `react/index.mjs`, `react/index.d.ts` listed in `package.json` `"files"`) so Webpack 4 and TypeScript `< 4.7` (`"moduleResolution": "node"`) resolve ESM, CommonJS, and TypeScript declarations cleanly.
- **XHR Header Access Hardening & `<head>` Meta Tag Ordering Guidance**:
  - Wrap `xhr.getResponseHeader("x-request-id")` in `try { ... } catch (_err) {}` inside `packages/sentrace/src/browser.ts` so aborted or cross-origin `XMLHttpRequest` instances never throw during `loadend` breadcrumb recording.
  - Document in `README.md`, `packages/sentrace/README.md`, and `lib/generators/sentrace/install/install_generator.rb` that `<%= sentrace_meta_tags %>` must be rendered in `<head>` before synchronous `<script>`, `javascript_pack_tag`, `javascript_include_tag`, or `yield(:head)` tags.

### Out of Scope (Aligned with `SPEC.md` Section 2 Non-Goals)

- No React component render profiling, spans, transactions, Web Vitals, session replay, user feedback modal widgets, or attachments.
- No new PostgreSQL tables, columns, or GIN indexes (`contexts.react.componentStack` and `exception.mechanism` already fit within existing bounded `sentrace_events.event_data` `jsonb` limits in `SPEC.md` Sections 4–6).
- No runtime npm `"dependencies"` in `packages/sentrace/package.json`.

## Capabilities

### New Capabilities

<!-- None: React error boundary and ES2019 bundle compatibility extend the existing `browser-sdk` and `rails-frontend-integration` capabilities. -->

### Modified Capabilities

- `browser-sdk`: Enforce ES2018/ES2019 syntax compatibility across all emitted JS/MJS/CJS bundles, harden `XMLHttpRequest` `getResponseHeader` error handling, and add `sentrace/react` (`ErrorBoundary` + `withErrorBoundary`) with optional `react >= 16.8.0` peer dependency and dual `"exports"` + top-level `react/` directory resolution.
- `rails-frontend-integration`: Enforce ES2018/ES2019 syntax compatibility on synced Rails engine JavaScript assets (`app/assets/javascripts/sentrace*.js`), resilient XHR `X-Request-Id` extraction, and `<head>` ordering guidance for `sentrace_meta_tags` in generator output and documentation.

## Impact

- **Frontend SDK (`packages/sentrace`)**: `src/*.ts`, new `src/react.ts`, `scripts/build.mjs`, `package.json` (`exports`, `files`, optional `peerDependencies`), generated `dist/react.{mjs,cjs,d.ts}` and `react/{package.json,index.js,index.mjs,index.d.ts}`, synced `app/assets/javascripts/sentrace*.js`, and `packages/sentrace/test/*.test.mjs`.
- **Rails Generator & Docs**: `lib/generators/sentrace/install/install_generator.rb`, `spec/generators/sentrace/install_generator_spec.rb`, `README.md`, and `packages/sentrace/README.md`.
