## MODIFIED Requirements

### Requirement: Lazy ActionView meta tag helper with public-only DSN enforcement
When `ActionView` is loaded, Sentrace SHALL register `sentrace_meta_tags` emitting HTML-escaped `sentrace-dsn`, `sentrace-environment`, `sentrace-release`, and `sentrace-request-id` meta tags with secrets stripped. When `frontend_dsn` is blank, it MUST auto-resolve a same-origin DSN from `project || project_slug || project_id`, `request.base_url`, mount path, and a cached `[project_id, public_key]` tuple (zero SQL after warmup), rescuing DB/Sentrace errors to return `""`.

#### Scenario: Rendering meta tags in a Rails layout strips DSN secrets and includes request_id
- **GIVEN** `frontend_dsn = "https://pub123:supersecret@app.example.com/sentrace/1"`, `deployment_environment = "production"`, `release = "abc1234"`, and `request.request_id = "req-999"`
- **WHEN** a Rails template renders `sentrace_meta_tags`
- **THEN** the HTML output contains `https://pub123@app.example.com/sentrace/1`, `"production"`, `"abc1234"`, and `"req-999"` and MUST NOT contain `"supersecret"`

#### Scenario: Auto-resolving same-origin public DSN from configured project_slug with zero SQL after warmup
- **GIVEN** `frontend_dsn = nil`, `project_slug = "shop-web"` provisioned with active public key `"pub_live_1"` and ID `42`, `Sentrace::Engine` mounted at `"/sentrace"`, and `request.base_url = "https://shop.example.com"`
- **WHEN** `sentrace_meta_tags` is rendered across two consecutive requests
- **THEN** both renders emit `<meta name="sentrace-dsn" content="https://pub_live_1@shop.example.com/sentrace/42">`, explicit `config.frontend_dsn` overrides auto-resolution when set, and the second render executes zero SQL queries against `sentrace_projects` or `sentrace_project_keys`

#### Scenario: Keyless project or unmigrated database returns empty meta tags without raising
- **GIVEN** `frontend_dsn = nil` and `project_slug = "no-keys-app"` whose active project keys have all been revoked (or where `ActiveRecord::StatementInvalid` / `ActiveRecord::NoDatabaseError` is raised)
- **WHEN** a Rails layout renders `sentrace_meta_tags`
- **THEN** `sentrace_meta_tags` returns `""` without raising `Sentrace::Error` or crashing host HTML rendering

#### Scenario: API-only Rails application boots without loading ActionView
- **GIVEN** a Rails application configured with `config.api_only = true` and without `action_view/railtie`
- **WHEN** the application boots with `Sentrace::Engine`
- **THEN** initialization succeeds without requiring `ActionView`

#### Scenario: Install generator documents placing sentrace_meta_tags before synchronous head scripts
- **WHEN** `bin/rails generate sentrace:install` runs in a host Rails application
- **THEN** the printed frontend setup instructions explicitly state that `<%= sentrace_meta_tags %>` must be rendered in `<head>` before synchronous `<script>`, `javascript_pack_tag`, or `javascript_include_tag` tags

### Requirement: Engine-bundled JavaScript assets for offline Rails asset delivery
The `sentrace` gem SHALL ship synced ES2019-compatible ESM (`app/assets/javascripts/sentrace.js`) and browser global (`app/assets/javascripts/sentrace.browser.js`) bundles (`0.1.2`) inside the engine containing zero ES2020+ syntax tokens so Propshaft, Sprockets, Importmap, and Webpacker 5 / Webpack 4 hosts can serve or parse the SDK without external CDNs or `node_modules` transpilation.

#### Scenario: Engine JavaScript bundles match built npm artifacts
- **WHEN** the `sentrace` frontend package is built for release
- **THEN** `app/assets/javascripts/sentrace.js` and `app/assets/javascripts/sentrace.browser.js` exist in the gem package tree, match the compiled ESM and browser bundles (`0.1.2`), and contain zero ES2020+ syntax tokens

## ADDED Requirements

### Requirement: Public programmatic frontend DSN helpers for SPA configuration endpoints
Sentrace SHALL expose `Sentrace.frontend_dsn(base_url: nil, request: nil, project: nil)` and `Sentrace.resolve_frontend_dsn(base_url:, project: nil)` sharing the same precedence (`config.frontend_dsn` first, then `project || config.project_slug || config.project_id`), secret-stripping, mount-prefix resolution, thread-safe in-memory `[project_id, public_key]` cache, and non-raising fallback (`nil`) as `sentrace_meta_tags`.

#### Scenario: Resolving public DSN in an SPA JSON config controller
- **GIVEN** `frontend_dsn = nil`, `project_slug = "spa-app"` provisioned with active public key `"pub_spa"` and ID `9`, and an incoming `ActionDispatch::Request` with `base_url = "https://spa.example.com"`
- **WHEN** a controller calls `Sentrace.frontend_dsn(request: request)`
- **THEN** the helper returns `"https://pub_spa@spa.example.com/sentrace/9"` using the cached project key tuple and returns `nil` safely when no DSN or active key is available
