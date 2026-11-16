# sentrace

Zero-dependency, `@sentry/browser`-compatible frontend error capturing SDK for [**Sentrace**](https://github.com/kemalelmizan/sentrace) — self-hosted, PostgreSQL-backed error tracking for Ruby on Rails with a federated Model Context Protocol (MCP) interface.

## Highlights

- **`@sentry/browser`-compatible API**: `init`, `captureException`, `captureMessage`, `captureEvent`, `addBreadcrumb`, `setTag`, `setTags`, `setUser`, `setContext`, `setExtra`, `withScope`, `getCurrentScope`, `flush`, `close`, `beforeSend`, `ignoreErrors`, `denyUrls`, and `allowUrls`.
- **Standard Sentry v7 Envelopes**: Uses `fetch(..., { keepalive: true })` with `navigator.sendBeacon` unload/offline fallback and parses V8/Chromium, Firefox/SpiderMonkey, and Safari/JavaScriptCore stack traces (`lineno` + `colno`).
- **Cohesive Ruby on Rails & Hotwire integration**:
  - Zero-argument `Sentrace.init()` auto-discovers `<meta name="sentrace-*">` tags rendered by Rails `sentrace_meta_tags`.
  - Built-in Hotwire Turbo hooks (`turbo:visit`, `turbo:load`, `turbo:fetch-request-error`, `turbo:frame-missing`) and `registerStimulusErrorHandler(application)` for Stimulus controllers.
  - Automatic `X-Request-Id` (`request_id`) extraction from Rails `fetch` / `XMLHttpRequest` / Turbo responses so AI coding agents can correlate frontend JS crashes with backend Rails exceptions via Sentrace MCP.
- **Zero runtime dependencies**: Ships ESM (`sentrace`), CommonJS (`sentrace`), TypeScript declarations, and an IIFE browser global bundle (`sentrace/browser` -> `window.Sentrace`).

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

1. Configure `frontend_dsn` in `config/initializers/sentrace.rb`:

```ruby
Sentrace.configure do |config|
  config.frontend_dsn = ENV["SENTRACE_FRONTEND_DSN"] # e.g. "https://<public_key>@app.example.com/sentrace/1"
  config.release = ENV["APP_RELEASE"]
end
```

2. Render `sentrace_meta_tags` inside `<head>` in `app/views/layouts/application.html.erb`:

```erb
<head>
  <%= sentrace_meta_tags %>
</head>
```

3. Initialize `sentrace` in `app/javascript/application.js` (auto-reads DSN, environment, release, and `request_id` from `<meta>` tags, and instruments Hotwire Turbo automatically):

```js
import * as Sentrace from "sentrace";
import { Application } from "@hotwired/stimulus";

Sentrace.init();

const application = Application.start();
Sentrace.registerStimulusErrorHandler(application);
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
  dsn: "https://<public_key>@api.example.com/sentrace/1",
  environment: "production",
  release: "2026.11.0",
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
