# Design

## Context

See `proposal.md` for motivation. `packages/sentrace` builds offline with zero `node_modules` dependencies via `packages/sentrace/scripts/build.mjs`, which invokes Node's built-in `stripTypeScriptTypes(source, { mode: "strip" })`. Because `stripTypeScriptTypes` performs type erasure without AST downleveling:
1. Any ES2020+ JavaScript operator in `src/*.ts` (`?.`, `??`, `??=`, `||=`, `&&=`) passes straight through into `dist/*.mjs`, `dist/*.cjs`, `dist/sentrace.browser.js`, and `app/assets/javascripts/sentrace*.js`.
2. Any TypeScript class field declaration without `declare` (such as `readonly config: FrozenClientConfig;` or `private closed = false;` in `BrowserClient` and `Scope`) is stripped to an ES2022 class field (`config;` or `closed = false;`), which fails Webpack 4.46 / Acorn 6 (`ecmaVersion: 2019`) when `@rails/webpacker 5.4` parses `.mjs` modules in `node_modules` without `babel-loader`.
3. `packages/sentrace/package.json` sets `"type": "module"`, which affects how Node and legacy bundlers interpret `.js` files in subdirectories unless scoped with a nested `package.json`.

Backend storage and ingestion remain completely unchanged: Phase 9 already updated `Sentrace::Ingestion::EventNormalizer` (`lib/sentrace/ingestion/event_normalizer.rb`) to preserve bounded `exception.mechanism` (`{ "type" => ..., "handled" => ... }`), and `contexts.react.componentStack` is stored inside `sentrace_events.event_data["contexts"]["react"]` within the existing `max_context_entries` (`16`) and `max_context_bytes` (`8 KB`) bounds (`SPEC.md` Sections 4–6; zero schema migrations or GIN indexes).

## Goals / Non-Goals

**Goals:**
- Emit 100% ES2018/ES2019-compatible JavaScript across every published and engine-synced bundle while keeping zero runtime npm dependencies and zero external build-tool dependencies.
- Provide `sentrace/react` (`ErrorBoundary` + `withErrorBoundary`) compatible with React `>= 16.8.0` (including React 17/18/19) and `@sentry/react` `<ErrorBoundary>` prop conventions, resolvable under both modern `"exports"` and legacy Webpack 4 / TypeScript 4.4 `"moduleResolution": "node"`.
- Guard `XMLHttpRequest.prototype.getResponseHeader` against `InvalidStateError` / security exceptions on aborted or cross-origin requests.
- Enforce ES2019 syntax compliance continuously via an automated lexer/AST-token test in `packages/sentrace/test/`.

**Non-Goals:**
- Adding Babel, Rollup, esbuild, or TypeScript compiler (`tsc`) `devDependencies` that would require network access or `node_modules` to build `packages/sentrace`.
- React Profiler / performance tracing wrappers (`withProfiler`), Redux enhancers, or React Router instrumentation (excluded by `SPEC.md` Section 2 Non-Goals).

## Decisions

### 1. Erase Class Fields via TypeScript `declare` Property Modifiers + Constructor Initialization
- **Choice**: Prefix class property type declarations in `Scope` and `BrowserClient` with `declare` (e.g., `declare readonly config: FrozenClientConfig;`, `declare private closed: boolean;`) and assign all initial values inside `constructor(...)`. Replace `?.`, `??`, and bare `catch {}` across `src/*.ts` with explicit truthiness/`!== null && !== undefined` checks and `catch (_err) {}`.
- **Rationale**: Node's `stripTypeScriptTypes` completely erases `declare` property declarations, emitting pure ES2015 `class` bodies containing only `constructor` and methods. Replacing `catch {}` with `catch (_err) {}` satisfies even ES2018 parsers alongside Acorn 6 (`ecmaVersion: 2019`).
- **Alternatives considered**: Adding esbuild/SWC to downlevel ES2022 syntax — rejected because `packages/sentrace` intentionally builds with zero third-party packages using only Node's standard library.

### 2. Prototype-Inherited `ErrorBoundary` in `sentrace/react` Using `React.createElement` for Functional `fallback`
- **Choice**: Implement `ErrorBoundary` in `packages/sentrace/src/react.ts` as an ES2018-clean `React.Component` subclass (`Object.setPrototypeOf` / `Object.create` or `extends React.Component` with constructor state initialization and bound `resetError` assigned in `constructor`). Handle `fallback` in `render()` when `this.state.hasError` is `true` as:
  1. `React.isValidElement(fallback)` -> return `fallback` directly.
  2. `typeof fallback === "function"` -> return `React.createElement(fallback, { error, componentStack, eventId, resetError })`.
  3. Otherwise -> return `null`.
- **Rationale**: Using `React.createElement(fallback, fallbackProps)` for **all** callable `fallback` values uniformly supports (a) class components (`class MyFallback extends React.Component`), (b) function components that call React Hooks (`useState`, `useContext` — which would crash with `Invalid hook call` if invoked as `fallback(fallbackProps)` directly!), and (c) inline render functions `({ error, componentStack, eventId, resetError }) => <div />` in React `>= 16.8.0`. This matches `@sentry/react`'s `<Sentry.ErrorBoundary fallback={...}>` behavior.
- **Capture contract**: In `componentDidCatch(error, errorInfo)`, extract `componentStack = (errorInfo && typeof errorInfo.componentStack === "string") ? errorInfo.componentStack : ""` and capture inside `withScope` via `client.captureExceptionWithMeta(error, scope, undefined, { handled: false, mechanismType: "react.error_boundary" })` after setting `scope.setContext("react", { componentStack })` and invoking optional `props.beforeCapture(scope, error, componentStack)` (falling back to `generateEventId()` if Sentrace is not initialized). Store `eventId` and `componentStack` in component state (`setState`) and invoke `props.onError(error, componentStack, eventId)`.

### 3. Dual `"exports"` + Published `react/` Directory with Scoped `react/package.json`
- **Choice**: Emit:
  - `dist/react.mjs` (ESM importing `* as React from "react"` and helpers from `"./index.mjs"`), `dist/react.cjs` (CommonJS requiring `"react"` and `"./index.cjs"`), and `dist/react.d.ts` (`import * as React from "react"` + `import type { Scope } from "./index"`).
  - Top-level `packages/sentrace/react/` directory included in `package.json` `"files"`:
    - `react/package.json`: `{ "name": "sentrace/react", "type": "commonjs", "main": "./index.js", "module": "./index.mjs", "types": "./index.d.ts", "sideEffects": false }`
    - `react/index.js`: CommonJS re-export `module.exports = require("../dist/react.cjs");`
    - `react/index.mjs`: ESM re-export `export { ErrorBoundary, withErrorBoundary } from "../dist/react.mjs"; export { default } from "../dist/react.mjs";`
    - `react/index.d.ts`: TypeScript 4.4-compatible re-export `export * from "../dist/react"; export { default } from "../dist/react";`
  - Root `packages/sentrace/package.json` `"exports"` entry `"./react": { "types": "./dist/react.d.ts", "import": "./dist/react.mjs", "require": "./dist/react.cjs" }` plus `"./package.json": "./package.json"`, and optional peer dependency `"peerDependencies": { "react": ">=16.8.0" }` + `"peerDependenciesMeta": { "react": { "optional": true } }`.
- **Rationale**:
  - Root `package.json` has `"type": "module"`. Placing `"type": "commonjs"` inside `react/package.json` ensures `react/index.js` is valid CommonJS for Node CJS/Jest/Webpack `main` resolution, while `"module": "./index.mjs"` feeds Webpack 4 ESM tree-shaking (`@rails/webpacker 5.4`), `"types": "./index.d.ts"` (using extensionless `"../dist/react"` and `"./index"` specifiers) satisfies TypeScript 4.4 `"moduleResolution": "node"`, and root `"exports"` satisfies Node 18+/Vite/Webpack 5/TS 5+.

### 4. Automated Lexer Scanner for ES2020+ Syntax Regression Prevention
- **Choice**: Write a self-contained JS scanner in `packages/sentrace/test/es2019-compat.test.mjs` that strips comments, string literals, template literals, and regex literals from every emitted JS file (`dist/*`, `react/*`, `app/assets/javascripts/*`) and verifies zero occurrences of `?.`, `??`, `??=`, `||=`, `&&=`, `#private` identifiers, parameterless `catch {`, or class body field declarations.
- **Rationale**: Runs in milliseconds under `node --test` with zero external dependencies and prevents future TypeScript edits from reintroducing ES2020–ES2022 tokens.

## Risks / Trade-offs

- **[Risk] Naive replacement of `a ?? b` with `a || b` changes boolean/numeric semantics (`enabled: false`, `sampleRate: 0`, `maxBreadcrumbs: 0`)** → **Mitigation**: Use explicit nullish helper `function nullish<T>(val: T | null | undefined, fallback: T): T { return val !== undefined && val !== null ? val : fallback; }` or explicit `!== undefined && !== null` checks so `false` and `0` are preserved identically.
- **[Risk] Calling `setState` in `componentDidCatch` vs `getDerivedStateFromError` timing for `eventId` in `FallbackProps`** → **Mitigation**: `getDerivedStateFromError(error)` transitions `hasError: true, error` immediately so the broken child subtree is unmounted on the initial error render pass, and `componentDidCatch(error, errorInfo)` captures the event synchronously, updates `{ componentStack, eventId }` via `this.setState`, and calls `onError(error, componentStack, eventId)` — matching React's official two-phase error boundary lifecycle and `@sentry/react`.
