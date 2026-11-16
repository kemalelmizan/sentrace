# browser-sdk Specification

## Purpose
Provides a zero-dependency `@sentry/browser`-compatible TypeScript and browser JavaScript SDK (`sentrace` npm package) that captures client-side exceptions, messages, scopes, and breadcrumbs and delivers Sentry v7 envelopes to Sentrace.

## Requirements

### Requirement: Sentry-browser compatible top-level SDK API and filtering hooks
The `sentrace` npm package SHALL expose `init`, `captureException`, `captureMessage`, `captureEvent`, `addBreadcrumb`, `setTag`, `setTags`, `setUser`, `setContext`, `setExtra`, `withScope`, `getCurrentScope`, `getClient`, `isInitialized`, `flush`, and `close`, and SHALL honor `enabled`, `sampleRate`, `ignoreErrors`, `denyUrls`, `allowUrls`, and `beforeSend`.

#### Scenario: Capturing an exception with isolated withScope tags and user context
- **GIVEN** `sentrace` initialized with a valid DSN, `environment: "production"`, and `release: "v1.0.0"`
- **WHEN** application code sets a global tag, calls `withScope` to attach a scoped tag and user ID, and invokes `captureException`
- **THEN** the emitted event includes both the global and scoped tags plus user ID while subsequent events outside `withScope` retain only the global tag

#### Scenario: Dropping or mutating events via beforeSend and ignoreErrors
- **GIVEN** `sentrace` initialized with `ignoreErrors: [/ResizeObserver loop/]` and a `beforeSend` callback that returns `null` when `event.tags.drop === "true"`
- **WHEN** matching `ResizeObserver` or `drop: "true"` errors are captured
- **THEN** neither event is transmitted over the network

### Requirement: Cross-browser JavaScript stack trace parsing
The SDK SHALL parse V8/Chromium, SpiderMonkey/Firefox, and JavaScriptCore/Safari `Error.stack` strings into Sentry v7 stack frames containing `filename`, `function`, `lineno`, `colno`, and `in_app`, ordered from oldest caller frame to newest crash frame.

#### Scenario: Parsing V8, Firefox, and Safari stack traces into Sentry frame order
- **WHEN** `captureException` receives errors with V8 (`at fn (url:10:20)`), Firefox (`fn@url:10:20`), or Safari stack strings mixing `/assets/app.js` and `/node_modules/pkg/index.js`
- **THEN** frames are ordered oldest-to-newest with integer `lineno` and `colno`, marking application URLs `in_app: true` and `node_modules` frames `in_app: false`

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

### Requirement: Sentry v7 envelope serialization, transport fallback, and client privacy scrubbing
The SDK SHALL serialize events as newline-delimited Sentry v7 envelopes sent to `/api/:project_id/envelope?sentry_key=<public_key>&sentry_version=7&sentry_client=sentrace-js/<version>` via `fetch` (`keepalive: true`, `text/plain;charset=UTF-8`) with `navigator.sendBeacon` fallback, redacting credential and auth-session query parameters unless exempted by `allowFields` while preserving non-auth `*_session_id` keys.

#### Scenario: Delivering valid Sentry v7 envelope and redacting sensitive URL query parameters
- **GIVEN** `sentrace` initialized with DSN `https://pub123@errors.example.com/sentrace/7` on page `https://shop.example.com/reset?token=secret123&step=2`
- **WHEN** `captureMessage("Reset failed")` is called
- **THEN** the SDK posts a 3-line Sentry v7 envelope to `https://errors.example.com/sentrace/api/7/envelope?sentry_key=pub123&sentry_version=7&sentry_client=sentrace-js/0.1.1` with `token=[REDACTED]` and `step=2` in `request.url`

#### Scenario: Preserving domain session foreign keys and honoring allowFields in client URL scrubbing
- **GIVEN** `sentrace` initialized with `allowFields: ["token_present"]` on URL `https://app.example.com/reviews?calibration_session_id=77&session_id=sec_1&token_present=1&access_token=sec_2`
- **WHEN** URL scrubbing runs for `request.url` and navigation/fetch breadcrumbs
- **THEN** `calibration_session_id=77` and `token_present=1` remain intact while `session_id=[REDACTED]` and `access_token=[REDACTED]` are masked

### Requirement: Zero-dependency ESM, CommonJS, TypeScript, and browser global package outputs
The `sentrace` npm package (`0.1.1`) MUST declare zero runtime dependencies, ship ESM (`dist/index.mjs`), CommonJS (`dist/index.cjs`), TypeScript declarations (`dist/index.d.ts`), and an IIFE bundle (`dist/sentrace.browser.js` via `sentrace/browser` exposing `window.Sentrace`), and MUST emit zero ES2020+ syntax tokens across all published JavaScript bundles for ES2019 / Webpack 4 compatibility.

#### Scenario: Importing sentrace from ESM, CommonJS, and browser global bundle
- **WHEN** consumers load `sentrace` via ESM `import`, CommonJS `require`, or execute `dist/sentrace.browser.js` in a browser global scope
- **THEN** all three entrypoints expose the complete SDK surface with zero external runtime packages required

#### Scenario: All emitted bundles parse cleanly without ES2020+ syntax tokens
- **WHEN** the `sentrace` package is built (`dist/*.mjs`, `dist/*.cjs`, `dist/*.js`, `react/*.js`, `react/*.mjs`)
- **THEN** none of the emitted JavaScript files contain optional chaining (`?.`), nullish coalescing (`??`), logical assignment (`??=`, `||=`, `&&=`), ES2022 class field declarations, private `#fields`, or parameterless `catch {}` clauses

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
