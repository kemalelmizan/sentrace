# sentrace

Zero-dependency, `@sentry/browser`-compatible frontend error capturing SDK for [**Sentrace**](https://github.com/kemalelmizan/sentrace) — self-hosted, PostgreSQL-backed error tracking for Ruby on Rails with a federated Model Context Protocol (MCP) interface.

## Highlights

- **`@sentry/browser`-compatible API**: `init`, `captureException`, `captureMessage`, `captureEvent`, `addBreadcrumb`, `setTag`, `setTags`, `setUser`, `setContext`, `setExtra`, `withScope`, `getCurrentScope`, `isInitialized`, `isEnabled`, `lastEventId`, `flush`, `close`, `beforeSend`, `ignoreErrors`, `denyUrls`, `allowUrls`, `redactFields`, and `allowFields`.
- **Idempotent `Sentrace.init()`**: Safe to call more than once (for example, zero-arg `Sentrace.init()` at bundle load followed by a second `Sentrace.init({ dsn, release })` after fetching `/api/v1/configs`) — prior listeners and wrappers are cleanly deactivated without duplicating breadcrumbs/captures, clobbering third-party `fetch`/`XMLHttpRequest` wrappers, or clearing `globalScope`.
- **React `<ErrorBoundary>` (`sentrace/react`)**: Drop-in `@sentry/react`-compatible `ErrorBoundary` and `withErrorBoundary` (`react >= 16.8.0` optional `peerDependency` only) capturing unhandled render/lifecycle errors with `mechanism: { type: "react.error_boundary", handled: false }` and `contexts.react.componentStack`.
- **Legacy & Modern Toolchain Ready**: Emits pure ES2018/ES2019 bundles (zero ES2020+ syntax tokens) with both `package.json` `"exports"` and a top-level `react/` directory so `@rails/webpacker 5.4` (`webpack 4.46` / Acorn 6), TypeScript `>= 4.4` (`"moduleResolution": "node"`), Webpack 5, and Vite all work out of the box without `node_modules` transpilation.
- **Standard Sentry v7 Envelopes**: Uses `fetch(..., { keepalive: true })` with `navigator.sendBeacon` unload/offline fallback and parses V8/Chromium, Firefox/SpiderMonkey, and Safari/JavaScriptCore stack traces (`lineno` + `colno`).
- **Cohesive Ruby on Rails & Hotwire integration**:
  - Zero-argument `Sentrace.init()` auto-discovers `<meta name="sentrace-*">` tags rendered by Rails `sentrace_meta_tags`.
  - Built-in Hotwire Turbo hooks (`turbo:visit`, `turbo:load`, `turbo:fetch-request-error`, `turbo:frame-missing`) and `registerStimulusErrorHandler(application)` for Stimulus controllers.
  - Automatic, fault-tolerant `X-Request-Id` (`request_id`) extraction from Rails `fetch` / `XMLHttpRequest` / Turbo responses so AI coding agents can correlate frontend JS crashes with backend Rails exceptions via Sentrace MCP.
- **Zero runtime dependencies**: Ships ESM (`sentrace`), CommonJS (`sentrace`), React (`sentrace/react`), TypeScript declarations, and an IIFE browser global bundle (`sentrace/browser` -> `window.Sentrace`).

## Installation

```bash
npm install sentrace
```

Pair with the [`sentrace` RubyGem](https://rubygems.org/gems/sentrace) in your Ruby on Rails application:

```bash
bundle add sentrace
bin/rails generate sentrace:install
```

## Full-Stack Ruby on Rails Quickstart

1. Configure `project_slug` in `config/initializers/sentrace.rb` (`<%= sentrace_meta_tags %>` and `Sentrace.frontend_dsn(request: request)` automatically resolve and cache the same-origin public DSN from your active `Sentrace::ProjectKey` with zero extra environment variables; set `config.frontend_dsn` only for cross-origin SPAs or custom public hosts):

```ruby
Sentrace.configure do |config|
  config.project_slug = "my-app"
  config.release = ENV["APP_RELEASE"]
  # Optional override for cross-origin SPAs or CDN hosts:
  # config.frontend_dsn = ENV["SENTRACE_FRONTEND_DSN"]
end
```

2. Render `sentrace_meta_tags` inside `<head>` in `app/views/layouts/application.html.erb` **before** any synchronous `<script>`, `javascript_pack_tag`, `javascript_include_tag`, or `yield(:head)` tags:

```erb
<head>
  <%= sentrace_meta_tags %>
  <%= javascript_pack_tag "application" %>
  <%= yield(:head) %>
</head>
```

> **Why `<head>` ordering matters:** Synchronous `<script>` / Webpacker `javascript_pack_tag` bundles placed in `<head>` execute before later `<meta>` tags are parsed into `document`. Placing `<%= sentrace_meta_tags %>` first guarantees zero-argument `Sentrace.init()` discovers `dsn`, `environment`, `release`, and `request_id` immediately.

3. Initialize `sentrace` in `app/javascript/application.js` (auto-reads DSN, environment, release, and `request_id` from `<meta>` tags, and instruments Hotwire Turbo automatically):

```js
import * as Sentrace from "sentrace";
import { Application } from "@hotwired/stimulus";

Sentrace.init();

const application = Application.start();
Sentrace.registerStimulusErrorHandler(application);
```

## React Integration (`sentrace/react`)

`sentrace/react` exports `ErrorBoundary` and `withErrorBoundary` (`react >= 16.8.0` is an optional peer dependency; non-React apps do not need `react` installed). `fallback` accepts a React function or class component (`FallbackComponent`), a React element (`<div />`), or a render function `({ error, componentStack, eventId, resetError }) => ReactNode`:

```tsx
import * as React from "react";
import { ErrorBoundary, withErrorBoundary, FallbackProps } from "sentrace/react";

function ErrorFallback({ error, eventId, resetError }: FallbackProps) {
  return (
    <div role="alert">
      <p>Something went wrong (ref: {eventId}).</p>
      <button type="button" onClick={resetError}>
        Try again
      </button>
    </div>
  );
}

export function AppRoot() {
  return (
    <ErrorBoundary
      fallback={ErrorFallback}
      onError={(error, componentStack, eventId) => {
        // Optional side-effect hook after Sentrace capture
      }}
      onReset={() => {
        // Optional state cleanup before re-rendering children
      }}
    >
      <Dashboard />
    </ErrorBoundary>
  );
}

export const SafeCheckout = withErrorBoundary(CheckoutWidget, {
  fallback: <div>Checkout temporarily unavailable.</div>
});
```

### Importmap / Propshaft / `<script>` Tag Usage

When using `importmap-rails` or Propshaft without a Node bundler, `sentrace` is also bundled directly inside the `sentrace` RubyGem (`sentrace.js` ESM and `sentrace.browser.js` global `window.Sentrace`), or can be pinned from npm:

```bash
bin/importmap pin sentrace
```

## Standalone / SPA (`@sentry/browser`-Compatible) Usage

```ts
import * as Sentrace from "sentrace";

Sentrace.init({
  dsn: "https://pub_key@api.example.com/sentrace/1",
  environment: "production",
  release: "2026.11.0",
  allowFields: ["token_present"],
  ignoreErrors: [/ResizeObserver loop/],
  beforeSend(event) {
    return event;
  }
});

Sentrace.setUser({ id: "user_42" });
Sentrace.setTag("surface", "checkout");

Sentrace.withScope((scope) => {
  scope.setExtra("cartItems", 3);
  Sentrace.captureException(new Error("Payment authorization failed"));
});
```

For cross-origin SPAs posting to a Rails API host, allow your SPA origin in `config/initializers/sentrace.rb`:

```ruby
Sentrace.configure do |config|
  config.cors_allowed_origins = ["https://app.example.com"]
end
```

## License

Released under the [MIT License](LICENSE.txt).
