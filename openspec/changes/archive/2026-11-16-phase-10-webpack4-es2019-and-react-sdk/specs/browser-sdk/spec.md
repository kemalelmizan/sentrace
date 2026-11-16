## MODIFIED Requirements

### Requirement: Global browser error and breadcrumb instrumentation
When initialized in a browser environment, the SDK SHALL attach removable listeners for `error` and `unhandledrejection`, SHALL record bounded ring-buffer breadcrumbs (`maxBreadcrumbs`, default `20`) for UI clicks, History API navigation, `fetch`, and `XMLHttpRequest` calls without capturing request or response bodies, and MUST NOT throw when `XMLHttpRequest.getResponseHeader` throws on aborted or cross-origin requests.

#### Scenario: Unhandled promise rejection includes preceding click and fetch breadcrumbs
- **GIVEN** `sentrace` initialized in a browser context with `maxBreadcrumbs: 5`
- **WHEN** the user clicks a button, triggers a `fetch("/checkout")` returning HTTP `500`, and an unhandled promise rejection occurs
- **THEN** the SDK captures the rejection event containing the click and HTTP `500` breadcrumbs in chronological order without request body payloads

#### Scenario: Aborted or cross-origin XMLHttpRequest throwing in getResponseHeader still records breadcrumb safely
- **GIVEN** `sentrace` initialized in a browser context with `XMLHttpRequest` instrumentation active
- **WHEN** an `XMLHttpRequest` completes (`loadend`) and `xhr.getResponseHeader("x-request-id")` throws an exception (such as `InvalidStateError` on an aborted or cross-origin request)
- **THEN** the `loadend` listener MUST NOT throw an uncaught error and SHALL record the `xhr` breadcrumb with the scrubbed URL and status metadata

### Requirement: Zero-dependency ESM, CommonJS, TypeScript, and browser global package outputs
The `sentrace` npm package (`0.1.0`) MUST declare zero runtime dependencies, ship ESM (`dist/index.mjs`), CommonJS (`dist/index.cjs`), TypeScript declarations (`dist/index.d.ts`), and an IIFE bundle (`dist/sentrace.browser.js` via `sentrace/browser` exposing `window.Sentrace`), and MUST emit zero ES2020+ syntax tokens across all published JavaScript bundles for ES2019 / Webpack 4 compatibility.

#### Scenario: Importing sentrace from ESM, CommonJS, and browser global bundle
- **WHEN** consumers load `sentrace` via ESM `import`, CommonJS `require`, or execute `dist/sentrace.browser.js` in a browser global scope
- **THEN** all three entrypoints expose the complete SDK surface with zero external runtime packages required

#### Scenario: All emitted bundles parse cleanly without ES2020+ syntax tokens
- **WHEN** the `sentrace` package is built (`dist/*.mjs`, `dist/*.cjs`, `dist/*.js`, `react/*.js`, `react/*.mjs`)
- **THEN** none of the emitted JavaScript files contain optional chaining (`?.`), nullish coalescing (`??`), logical assignment (`??=`, `||=`, `&&=`), ES2022 class field declarations, private `#fields`, or parameterless `catch {}` clauses

## ADDED Requirements

### Requirement: React ErrorBoundary and legacy bundler module resolution
The `sentrace` package SHALL expose `ErrorBoundary` and `withErrorBoundary` via `sentrace/react` (with `react >= 16.8.0` as an optional `peerDependency` only), resolvable via both `package.json` `exports` and a top-level `react/` directory, accepting `fallback` components, elements, or render functions and capturing errors with `mechanism` `{ type: "react.error_boundary", handled: false }` and `contexts.react.componentStack`.

#### Scenario: Capturing render error and rendering FallbackComponent, React element, or render function
- **GIVEN** `sentrace` initialized with a valid DSN and a React component tree wrapped in `<ErrorBoundary fallback={Fallback} onError={onError} onReset={onReset}>`
- **WHEN** a child component throws during rendering with `errorInfo.componentStack`
- **THEN** `ErrorBoundary` captures an unhandled exception event with `exception.values[0].mechanism` set to `{ type: "react.error_boundary", handled: false }` and `contexts.react.componentStack` populated, invokes `onError(error, componentStack, eventId)`, renders `Fallback` (whether passed as a function/class component, React element, or render function receiving `{ error, componentStack, eventId, resetError }`), and invokes `onReset` while clearing error state when `resetError()` is called

#### Scenario: Resolving sentrace/react across modern exports and legacy node module resolution
- **GIVEN** `sentrace` installed in `node_modules/sentrace` alongside `react`
- **WHEN** a consumer imports `sentrace/react` via modern ESM/CJS `"exports"` or via legacy directory resolution (`node_modules/sentrace/react/package.json`, `react/index.mjs`, `react/index.js`, `react/index.d.ts` under Webpack 4 and TypeScript 4.4 `"moduleResolution": "node"`)
- **THEN** `ErrorBoundary` and `withErrorBoundary` resolve cleanly with zero runtime npm dependencies added to `sentrace`
