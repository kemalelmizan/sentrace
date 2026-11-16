## MODIFIED Requirements

### Requirement: Lazy ActionView meta tag helper with public-only DSN enforcement
When `ActionView` is loaded, Sentrace SHALL register `sentrace_meta_tags` emitting HTML-escaped `<meta name="sentrace-dsn">`, `sentrace-environment`, `sentrace-release`, and `sentrace-request-id` tags while stripping any DSN secret key, returning an empty string when no DSN is configured, and documenting in generator instructions that `sentrace_meta_tags` MUST precede synchronous `<script>` and pack tags in `<head>`.

#### Scenario: Rendering meta tags in a Rails layout strips DSN secrets and includes request_id
- **GIVEN** `frontend_dsn = "https://pub123:supersecret@app.example.com/sentrace/1"`, `deployment_environment = "production"`, `release = "abc1234"`, and `request.request_id = "req-999"`
- **WHEN** a Rails template renders `sentrace_meta_tags`
- **THEN** the HTML output contains `https://pub123@app.example.com/sentrace/1`, `"production"`, `"abc1234"`, and `"req-999"` and MUST NOT contain `"supersecret"`

#### Scenario: API-only Rails application boots without loading ActionView
- **GIVEN** a Rails application configured with `config.api_only = true` and without `action_view/railtie`
- **WHEN** the application boots with `Sentrace::Engine`
- **THEN** initialization succeeds without requiring `ActionView`

#### Scenario: Install generator documents placing sentrace_meta_tags before synchronous head scripts
- **WHEN** `bin/rails generate sentrace:install` runs in a host Rails application
- **THEN** the printed frontend setup instructions explicitly state that `<%= sentrace_meta_tags %>` must be rendered in `<head>` before synchronous `<script>`, `javascript_pack_tag`, or `javascript_include_tag` tags

### Requirement: Engine-bundled JavaScript assets for offline Rails asset delivery
The `sentrace` gem SHALL ship synced ES2019-compatible ESM (`app/assets/javascripts/sentrace.js`) and browser global (`app/assets/javascripts/sentrace.browser.js`) bundles inside the engine containing zero ES2020+ syntax tokens so Propshaft, Sprockets, Importmap, and Webpacker 5 / Webpack 4 hosts can serve or parse the SDK without external CDNs or `node_modules` transpilation.

#### Scenario: Engine JavaScript bundles match built npm artifacts
- **WHEN** the `sentrace` frontend package is built for release
- **THEN** `app/assets/javascripts/sentrace.js` and `app/assets/javascripts/sentrace.browser.js` exist in the gem package tree, match the compiled ESM and browser bundles, and contain zero ES2020+ syntax tokens
