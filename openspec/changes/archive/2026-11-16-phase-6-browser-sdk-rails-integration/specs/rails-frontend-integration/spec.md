# rails-frontend-integration Specification

## Purpose
Integrates the `sentrace` browser SDK cohesively with Ruby on Rails layouts, asset delivery, Hotwire (Turbo and Stimulus), and backend `X-Request-Id` tracing without coupling API-only Rails applications to `ActionView` or a specific asset pipeline.

## ADDED Requirements

### Requirement: Lazy ActionView meta tag helper with public-only DSN enforcement
When `ActionView` is loaded, Sentrace SHALL register `sentrace_meta_tags` emitting HTML-escaped `<meta name="sentrace-dsn">`, `sentrace-environment`, `sentrace-release`, and `sentrace-request-id` tags while stripping any DSN secret key and returning an empty string when no DSN is configured.

#### Scenario: Rendering meta tags in a Rails layout strips DSN secrets and includes request_id
- **GIVEN** `frontend_dsn = "https://pub123:supersecret@app.example.com/sentrace/1"`, `deployment_environment = "production"`, `release = "abc1234"`, and `request.request_id = "req-999"`
- **WHEN** a Rails template renders `sentrace_meta_tags`
- **THEN** the HTML output contains `https://pub123@app.example.com/sentrace/1`, `"production"`, `"abc1234"`, and `"req-999"` and MUST NOT contain `"supersecret"`

#### Scenario: API-only Rails application boots without loading ActionView
- **GIVEN** a Rails application configured with `config.api_only = true` and without `action_view/railtie`
- **WHEN** the application boots with `Sentrace::Engine`
- **THEN** initialization succeeds without requiring `ActionView`

### Requirement: Automatic Rails meta discovery and Hotwire Turbo / Stimulus hooks
Calling `init()` (or `initRails()`) in a browser document containing `sentrace-*` `<meta>` tags SHALL auto-discover `dsn`, `environment`, `release`, and `request_id`, attach Hotwire Turbo listeners (`turbo:load`, `turbo:visit`, `turbo:fetch-request-error`, `turbo:frame-missing`), and provide `registerStimulusErrorHandler(application)`.

#### Scenario: Zero-argument init() discovers Rails meta tags and captures Stimulus and Turbo errors
- **GIVEN** a DOM document containing `<meta name="sentrace-dsn" content="https://pub123@app.example.com/sentrace/1">` and `<meta name="sentrace-request-id" content="req-initial">`
- **WHEN** `init()` is called with no `dsn` argument, `registerStimulusErrorHandler` wraps a Stimulus app, and a Stimulus controller error or `turbo:fetch-request-error` fires
- **THEN** the SDK initializes from the `<meta>` tags and emits normalized error events tagged with the active `request_id` and Stimulus/Turbo context

### Requirement: Cross-stack Rails X-Request-Id correlation
The browser SDK SHALL extract `X-Request-Id` response headers from `fetch` and `XMLHttpRequest` calls into HTTP breadcrumbs and tag failed request errors with `request_id`, matching backend Rails events whose `X-Request-Id` header or tag is recorded as `tags["request_id"]`.

#### Scenario: Failed fetch response correlates frontend error with backend Rails request_id
- **GIVEN** a Rails endpoint returning HTTP `500` with response header `X-Request-Id: req-corr-42` after logging a backend exception
- **WHEN** browser code calls `fetch("/orders")` and captures an exception for the failed response
- **THEN** both the backend Ruby event and the frontend JavaScript event carry `tags["request_id"] == "req-corr-42"` in Sentrace

### Requirement: Engine-bundled JavaScript assets for offline Rails asset delivery
The `sentrace` gem SHALL ship synced ESM (`app/assets/javascripts/sentrace.js`) and browser global (`app/assets/javascripts/sentrace.browser.js`) bundles inside the engine so Propshaft, Sprockets, and Importmap hosts can serve the SDK without external CDNs.

#### Scenario: Engine JavaScript bundles match built npm artifacts
- **WHEN** the `sentrace` frontend package is built for release
- **THEN** `app/assets/javascripts/sentrace.js` and `app/assets/javascripts/sentrace.browser.js` exist in the gem package tree and match the compiled ESM and browser bundles
