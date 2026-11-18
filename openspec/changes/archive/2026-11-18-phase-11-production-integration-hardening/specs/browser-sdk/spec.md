## MODIFIED Requirements

### Requirement: Sentry-browser compatible top-level SDK API and filtering hooks
The `sentrace` npm package SHALL expose `init`, `captureException`, `captureMessage`, `captureEvent`, `addBreadcrumb`, `setTag`, `setTags`, `setUser`, `setContext`, `setExtra`, `withScope`, `getCurrentScope`, `getClient`, `isInitialized`, `isEnabled`, `lastEventId`, `flush`, and `close`, and SHALL honor `enabled`, `sampleRate`, `ignoreErrors`, `denyUrls`, `allowUrls`, and `beforeSend`.

#### Scenario: Capturing an exception with isolated withScope tags and user context
- **GIVEN** `sentrace` initialized with a valid DSN, `environment: "production"`, and `release: "v1.0.0"`
- **WHEN** application code sets a global tag, calls `withScope` to attach a scoped tag and user ID, and invokes `captureException`
- **THEN** the emitted event includes both the global and scoped tags plus user ID while subsequent events outside `withScope` retain only the global tag

#### Scenario: Dropping or mutating events via beforeSend and ignoreErrors
- **GIVEN** `sentrace` initialized with `ignoreErrors: [/ResizeObserver loop/]` and a `beforeSend` callback that returns `null` when `event.tags.drop === "true"`
- **WHEN** matching `ResizeObserver` or `drop: "true"` errors are captured
- **THEN** neither event is transmitted over the network

#### Scenario: Querying isEnabled and lastEventId across lifecycle and filtered captures
- **GIVEN** an uninitialized `sentrace` SDK that is subsequently initialized with `enabled: false`, then re-initialized with a valid DSN and `enabled: true`
- **WHEN** `isEnabled()` and `lastEventId()` are checked before `init`, while disabled, after capturing a valid exception (`eventId`), after a `beforeSend`-dropped event, and after `close()`
- **THEN** `isEnabled()` returns `false` before `init`, `false` when disabled or missing a valid DSN, `true` when active with a valid DSN, and `false` after `close()`, while `lastEventId()` returns `undefined` initially, equals `eventId` after the accepted capture, remains `eventId` when a subsequent event is dropped, and resets to `undefined` after `close()`

### Requirement: Global browser error and breadcrumb instrumentation
When initialized in a browser environment, the SDK SHALL attach removable `error` and `unhandledrejection` listeners, record bounded breadcrumbs (`maxBreadcrumbs`, default `20`) for clicks, History navigation, `fetch`, and `XMLHttpRequest` without bodies, MUST NOT throw when `XMLHttpRequest.getResponseHeader` throws, and MUST deactivate prior listeners and wrappers while preserving `globalScope` across repeated `init()` calls without clobbering third-party wrappers.

#### Scenario: Unhandled promise rejection includes preceding click and fetch breadcrumbs
- **GIVEN** `sentrace` initialized in a browser context with `maxBreadcrumbs: 5`
- **WHEN** the user clicks a button, triggers a `fetch("/checkout")` returning HTTP `500`, and an unhandled promise rejection occurs
- **THEN** the SDK captures the rejection event containing the click and HTTP `500` breadcrumbs in chronological order without request body payloads

#### Scenario: Aborted or cross-origin XMLHttpRequest throwing in getResponseHeader still records breadcrumb safely
- **GIVEN** `sentrace` initialized in a browser context with `XMLHttpRequest` instrumentation active
- **WHEN** an `XMLHttpRequest` completes (`loadend`) and `xhr.getResponseHeader("x-request-id")` throws an exception (such as `InvalidStateError` on an aborted or cross-origin request)
- **THEN** the `loadend` listener MUST NOT throw an uncaught error and SHALL record the `xhr` breadcrumb with the scrubbed URL and status metadata

#### Scenario: Calling Sentrace.init a second time updates options without duplicate listeners or lost scope
- **GIVEN** `Sentrace.init({ dsn: dsnA, release: "v1" })` has run, `Sentrace.setUser({ id: "u-42" })` has populated `globalScope`, and third-party middleware subsequently wraps `window.fetch`
- **WHEN** `Sentrace.init({ dsn: dsnB, release: "v2" })` is called a second time, a `fetch("/api/ping")` executes through the third-party wrapper, and a single `window` `"error"` event fires
- **THEN** third-party `window.fetch` stays intact, exactly one `http` breadcrumb and exactly one unhandled error event are recorded (sent to `dsnB` with `release: "v2"` and `user.id: "u-42"`), with zero duplicate captures

### Requirement: Sentry v7 envelope serialization, transport fallback, and client privacy scrubbing
The SDK SHALL serialize events as newline-delimited Sentry v7 envelopes sent to `/api/:project_id/envelope?sentry_key=<public_key>&sentry_version=7&sentry_client=sentrace-js/<version>` via `fetch` (`keepalive: true`, `text/plain;charset=UTF-8`) with `navigator.sendBeacon` fallback, redacting credential and auth-session query parameters unless exempted by `allowFields` while preserving non-auth `*_session_id` keys.

#### Scenario: Delivering valid Sentry v7 envelope and redacting sensitive URL query parameters
- **GIVEN** `sentrace` initialized with DSN `https://pub123@errors.example.com/sentrace/7` on page `https://shop.example.com/reset?token=secret123&step=2`
- **WHEN** `captureMessage("Reset failed")` is called
- **THEN** the SDK posts a 3-line Sentry v7 envelope to `https://errors.example.com/sentrace/api/7/envelope?sentry_key=pub123&sentry_version=7&sentry_client=sentrace-js/0.1.2` with `token=[REDACTED]` and `step=2` in `request.url`

#### Scenario: Preserving domain session foreign keys and honoring allowFields in client URL scrubbing
- **GIVEN** `sentrace` initialized with `allowFields: ["token_present"]` on URL `https://app.example.com/reviews?calibration_session_id=77&session_id=sec_1&token_present=1&access_token=sec_2`
- **WHEN** URL scrubbing runs for `request.url` and navigation/fetch breadcrumbs
- **THEN** `calibration_session_id=77` and `token_present=1` remain intact while `session_id=[REDACTED]` and `access_token=[REDACTED]` are masked

### Requirement: Zero-dependency ESM, CommonJS, TypeScript, and browser global package outputs
The `sentrace` npm package (`0.1.2`) MUST declare zero runtime dependencies, ship ESM (`dist/index.mjs`), CommonJS (`dist/index.cjs`), TypeScript declarations (`dist/index.d.ts`), and an IIFE bundle (`dist/sentrace.browser.js` via `sentrace/browser` exposing `window.Sentrace`), and MUST emit zero ES2020+ syntax tokens across all published JavaScript bundles for ES2019 / Webpack 4 compatibility.

#### Scenario: Importing sentrace from ESM, CommonJS, and browser global bundle
- **WHEN** consumers load `sentrace` via ESM `import`, CommonJS `require`, or execute `dist/sentrace.browser.js` in a browser global scope
- **THEN** all three entrypoints expose the complete SDK surface (including `isEnabled` and `lastEventId`) with zero external runtime packages required

#### Scenario: All emitted bundles parse cleanly without ES2020+ syntax tokens
- **WHEN** the `sentrace` package is built (`dist/*.mjs`, `dist/*.cjs`, `dist/*.js`, `react/*.js`, `react/*.mjs`)
- **THEN** none of the emitted JavaScript files contain optional chaining (`?.`), nullish coalescing (`??`), logical assignment (`??=`, `||=`, `&&=`), ES2022 class field declarations, private `#fields`, or parameterless `catch {}` clauses
