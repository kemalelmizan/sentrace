# Sentrace

**Sentry-compatible error tracking for Ruby on Rails, with a federated Model Context Protocol (MCP) interface.**

Sentrace is a self-hosted, isolated Rails Engine (`Sentrace::Engine`) backed solely by PostgreSQL. It ingests application errors via the Sentry v7 envelope protocol (`sentry-ruby`), sanitizes sensitive fields before persistence, normalizes and deduplicates events, groups related occurrences into deterministic fingerprinted issues, and exposes issues, events, and trends across `local`, `staging`, and `production` environments through local `stdio` and remote Streamable HTTP MCP transports.

See [SPEC.md](SPEC.md) for the complete product specification and architecture.

## Architecture

```text
Rails application (sentry-ruby) + Browser / Hotwire / SPA (sentrace npm / @sentry/browser)
        |
        | POST /sentrace/api/:project_id/envelope (raw or gzip, CORS preflight supported)
        v
Sentrace::Ingestion::Processor
  -> EnvelopeParser -> EventNormalizer -> Sanitizer -> Issues::Fingerprint -> Issues::Grouper
        |
        v
PostgreSQL (sentrace_projects, sentrace_project_keys, sentrace_mcp_tokens, sentrace_issues, sentrace_events)
        |
        +---> Local MCP Server (stdio: ./bin/sentrace-mcp)
        |         \
        |          +---> EnvironmentRouter ---> Remote Streamable HTTP (/sentrace/mcp on staging & production)
        |
        +---> Retention::Cleaner (ActiveJob / Rake) & StorageStats
```

## Requirements

- Ruby `>= 3.2` (local development standardized on `3.3.14`)
- Rails `>= 6.1, < 9.0` (`Rack >= 2.2`)
- `pg` `>= 1.4, < 2.0`
- PostgreSQL `>= 12`
- Official [`mcp`](https://rubygems.org/gems/mcp) Ruby SDK (`~> 1.0`)
- Client SDK compatibility: verified against official [`sentry-ruby`](https://github.com/getsentry/sentry-ruby) `5.28.x` (`5.28.1` pinned in integration specs; Envelope protocol v7, raw & `gzip` transport, exceptions, messages, breadcrumbs, stack traces, and safe zero-write discarding of unsupported performance/session items)

## Host Application Installation

```bash
bundle add sentrace
bin/rails generate sentrace:install
bin/rails db:migrate
bin/rails sentrace:setup
```

Configure native in-process Ruby backend error capture (Rack/Rails, Sidekiq, and ActiveJob — **zero** HTTP hairpinning and no `sentry-ruby` required) in `config/initializers/sentrace.rb`:

```ruby
Sentrace.configure do |config|
  config.project_slug = ENV.fetch("SENTRACE_PROJECT_SLUG", "my-app")
  config.release = ENV["APP_RELEASE"]
  config.breadcrumbs_logger = %i[active_support_logger http_logger]
end

# Explicit capture & isolated scope API:
Sentrace.with_scope do |scope|
  scope.set_tag("flow", "checkout")
  scope.set_user(id: current_user.id)
  scope.add_breadcrumb(category: "payment", message: "Charging gateway")
  Sentrace.capture_exception(error)
end
```

Or if migrating incrementally from `sentry-ruby` (`~> 5.28`), route envelopes directly in-process via `Sentrace::SentryTransport` (zero outbound HTTP calls, zero DB writes for transactions/profiles/sessions) or over HTTP DSN:

```ruby
Sentry.init do |config|
  config.dsn = ENV.fetch("SENTRY_DSN")
  config.environment = Rails.env
  config.release = ENV["APP_RELEASE"]
  config.transport.transport_class = Sentrace::SentryTransport # optional zero-HTTP in-process transport
end
```

### Frontend Browser, React & Hotwire Integration (`sentrace` npm)

Install the zero-dependency [`sentrace` npm package](packages/sentrace/README.md) (`@sentry/browser`-compatible API, `sentrace/react` `<ErrorBoundary>`, Webpack 4 / ES2019 & TypeScript `>= 4.4` compatibility, plus native Rails `<meta>`, Hotwire Turbo, Stimulus, and `X-Request-Id` correlation):

```bash
npm install sentrace
```

> **Zero-config same-origin DSN & `<head>` ordering:** When `config.project_slug` (or `config.project_id`) is configured and `Sentrace::Engine` is mounted, `<%= sentrace_meta_tags %>` automatically builds and caches the public DSN from `request.base_url` + `/sentrace` with **zero SQL queries** per page render after warmup — no `SENTRACE_FRONTEND_DSN` environment variable required (`config.frontend_dsn` remains available as an override for cross-origin SPAs or CDN hosts). Render `<%= sentrace_meta_tags %>` inside `<head>` **before** any synchronous `<script>`, `javascript_pack_tag`, `javascript_include_tag`, or `yield(:head)` tags in `app/views/layouts/application.html.erb`.

```erb
<head>
  <%= sentrace_meta_tags %>
  <%= javascript_pack_tag "application" %>
  <%= yield(:head) %>
</head>
```

For SPAs fetching runtime configuration over JSON (`/api/v1/configs`), call `Sentrace.frontend_dsn(request: request)` (or `Sentrace.resolve_frontend_dsn(base_url: "https://app.example.com")`), which shares the same precedence, secret-stripping, and thread-safe in-memory cache:

```ruby
render json: {
  sentrace_dsn: Sentrace.frontend_dsn(request: request),
  release: Sentrace.configuration.release
}
```

Initialize in `app/javascript/application.js` (`Sentrace.init()` is idempotent and safely updates options without duplicating listeners if called again after a runtime config fetch; `Sentrace.isEnabled()` and `Sentrace.lastEventId()` are also exported):

```js
import * as Sentrace from "sentrace";
import { Application } from "@hotwired/stimulus";

Sentrace.init(); // Auto-discovers DSN, environment, release, and request_id from meta tags

const application = Application.start();
Sentrace.registerStimulusErrorHandler(application);
```

For React (`>= 16.8`, including React 17/18/19 under Webpack 4 / `@rails/webpacker 5.4`, Webpack 5, or Vite), wrap component trees with `ErrorBoundary` or `withErrorBoundary` from `sentrace/react` (drop-in compatible with `@sentry/react`):

```tsx
import { ErrorBoundary, withErrorBoundary } from "sentrace/react";

<ErrorBoundary fallback={FallbackComponent}>
  <App />
</ErrorBoundary>
```

## Configuration Reference

Configure Sentrace in `config/initializers/sentrace.rb`:

| Option | Default | Description |
|---|---|---|
| `enabled` | `true` | Enable or disable Sentrace envelope ingestion (`202 Accepted` no-op when `false`). |
| `deployment_environment` | `Rails.env` | Environment attribution label stamped on remote `/sentrace/mcp` responses. |
| `project_slug` / `project_id` | `nil` | Target `Sentrace::Project` for native in-process Ruby capture (`Rack`, `Sidekiq`, `ActiveJob`, `Sentrace.capture_*`). |
| `capture_unhandled_exceptions` | `true` when target project set | Automatically capture unhandled Rack/Rails, Sidekiq, and ActiveJob exceptions. |
| `sample_rate` | `1.0` | Probabilistic client sampling rate (`0.0..1.0`) for native Ruby capture. |
| `excluded_exceptions` | Standard Rails 404/400 + `ClientDisconnected` | Exceptions ignored by unhandled middleware/job integrations (explicit `capture_exception` still captures). |
| `before_send` | `nil` | Optional callable `->(raw_event_hash, hint) { hash_or_nil }` for mutating or dropping native Ruby events. |
| `breadcrumbs_logger` | `[]` | Safe instrumentation loggers (`%i[active_support_logger http_logger]`, omitting SQL binds and HTTP bodies). |
| `async_queue_size` | `256` | Bounded non-blocking `SizedQueue` capacity for transaction-isolated, fork-safe background persistence. |
| `capture_dispatch` | `:async` | `:async` (`SizedQueue` worker thread) or `:inline` (isolated from open/aborted caller transactions). |
| `frontend_dsn` | `nil` | Optional explicit public DSN override (auto-resolved from `project_slug` / `project_id` on same-origin apps when blank). |
| `release` | `ENV["APP_RELEASE"]` | Release label rendered by `sentrace_meta_tags`. |
| `cors_allowed_origins` | `[]` | Allowed browser `Origin`s (`Array` of origins or `"*"`) for `/api/:project_id/envelope`. |
| `retention_period` | `30.days` | How long normalized `sentrace_events` rows are retained before batch pruning. |
| `orphan_issue_retention_period` | `7.days` | Grace period before deleting `sentrace_issues` with zero remaining events. |
| `retention_batch_size` | `1000` | Maximum rows deleted per SQL statement during retention cleanup. |
| `max_envelope_size` | `1.megabyte` | Pre-parse compressed and decompressed envelope byte ceiling (`413` if exceeded). |
| `max_events_per_envelope` | `10` | Maximum error event items processed per HTTP envelope (`413` if exceeded). |
| `max_envelope_items` | `50` | Maximum total items (events + discarded telemetry) scanned per envelope (`413` if exceeded). |
| `max_message_bytes` | `4.kilobytes` | Maximum UTF-8 byte size for normalized exception/event messages. |
| `max_stack_frames` | `50` | Maximum stack frames retained per event (preserving innermost frames). |
| `max_breadcrumbs` | `20` | Maximum trailing breadcrumbs retained per event. |
| `max_tags` | `32` | Maximum tags retained per event (`max_tag_key_bytes = 64`, `max_tag_value_bytes = 256`). |
| `max_context_entries` | `16` | Maximum keys in `contexts` (`max_context_bytes = 8.kilobytes`). |
| `redact_fields` | `%w[password token authorization cookie credit_card]` | Case-insensitive key substrings replaced with `"[REDACTED]"` before persistence. |
| `allow_fields` | `[]` | Field names case-insensitively exempted from key-name redaction across URLs, tags, breadcrumbs, and contexts (e.g. `%w[token_present token_expires_in]`). |
| `retain_user_fields` | `[]` | Opt-in non-secret scalar `user` fields retained (`<= 256 B` each) alongside `user.id_hash` (e.g. `%w[id email username name]`). |
| `sanitizer` | `nil` | Optional callable `->(normalized_event_hash) { ... }` invoked before persistence. |
| `user_hash_secret` | `nil` | Secret key mixed with `project_id` to compute one-way HMAC-SHA256 `user.id_hash`. |
| `remote_timeout` | `5.0` | Default wall-clock timeout (seconds) for remote `:http` MCP federation requests. |
| `remote_ping_timeout` | `2.5` | Upper wall-clock bound (seconds) for concurrent `list_environments` `ping` health probes. |
| `environments` | `{ local: { transport: :local } }` | Map of `:local` and `:http` MCP environments (blank `:http` URL/token reports `"unconfigured"` safely). |
| `internal_authenticator` | `nil` | Optional callable `->(request) { boolean }` for `/sentrace/internal/*` routes (defaults to MCP bearer token auth). |
| `mcp_allowed_ips` | `[]` | Optional Array of IP/CIDR strings (e.g. `%w[10.0.0.0/8 203.0.113.5]`) enforced on `/sentrace/mcp` before bearer auth (`403` if outside allowlist). |
| `internal_allowed_ips` | `[]` | Optional Array of IP/CIDR strings enforced on `/sentrace/internal/*` before auth (`403` if outside allowlist). |
| `mcp_rate_limit_per_minute` | `120` | Per-IP 60-second request limit on `/sentrace/mcp` backed by `Rails.cache` (with in-memory fallback when `NullStore`), returning `429` + `Retry-After`. Set `nil` to disable. |
| `mcp_auth_failure_limit_per_minute` | `20` | Per-IP 60-second limit on failed `/sentrace/mcp` bearer authentication attempts (`429` + `Retry-After`). Set `nil` to disable. |
| `ingestion_rate_limit_per_minute` | `nil` | Optional per-project/IP 60-second rate limit on `/sentrace/api/:project_id/envelope` (`429` + `Retry-After`). |

### Rack / Puma Client Disconnects & Host RSpec Helpers

- **Fallback middleware `culprit` & socket-disconnect filtering:** When a Rack middleware raises before Rails routing populates `action_dispatch.request.path_parameters`, `RackMiddleware` automatically populates `culprit` as `"#{method} #{path}"` (without query string). `ActionController::Live::ClientDisconnected` and pure Puma socket-layer `IOError` (`stream closed in another thread` with zero `in_app` frames) are ignored out of the box, while `in_app` `IOError` / `Errno::ECONNRESET` / `Errno::EPIPE` errors from upstream services are preserved (use `config.before_send` if your app streams chunked responses and wants to drop specific `Errno::EPIPE` / `Errno::ECONNRESET` hints).
- **Host RSpec isolation (`Sentrace::TestHelpers` & `Sentrace.with_configuration`):** Generated initializers default `config.enabled` to `false` in `Rails.env.test?` unless `SENTRACE_ENABLED=true`. In specs that exercise Sentrace directly, include `Sentrace::TestHelpers` (or call `Sentrace.with_configuration`) to enable `:inline` capture and automatically restore configuration, caches, deduplicator state, and fiber scopes after each example:

```ruby
RSpec.describe "Error reporting" do
  include Sentrace::TestHelpers

  it "captures handled checkout errors synchronously" do
    project, _ = Sentrace::Project.ensure!(slug: "my-app")

    with_sentrace_test_config(project_slug: project.slug) do
      Sentrace.capture_message("Checkout fallback triggered", level: :warning)
      expect(project.events.count).to eq(1)
    end
  end
end
```

## Project & Credential Management

Ingestion DSN public keys and remote MCP bearer tokens are strictly isolated credentials:

```bash
# Ingestion DSN keys (for sentry-ruby SDKs)
bin/rails sentrace:projects
bin/rails "sentrace:projects:create[my-app]"
bin/rails "sentrace:projects:rotate_key[my-app]"

# Dedicated MCP bearer tokens (stored as SHA-256 digests, separate from DSNs)
bin/rails sentrace:mcp:tokens
bin/rails "sentrace:mcp:tokens:create[staging]"
READ_ONLY=true EXPIRES_IN_DAYS=30 bin/rails "sentrace:mcp:tokens:create[ci-readonly]"
bin/rails "sentrace:mcp:tokens:rotate[staging]"
bin/rails "sentrace:mcp:tokens:revoke[1]"
```

### Declarative CI/CD Credential Bootstrap (`sentrace:bootstrap`)

For non-interactive container deployments across `staging`, `pre-prod`, and `production`, seed deterministic project DSN public keys and digest-only MCP bearer tokens idempotently on boot without manual SSH/Rake runs or credential rotation:

```bash
SENTRACE_PROJECT_SLUG=my-app \
SENTRACE_PROJECT_PUBLIC_KEY=pub_prod_0123456789abcdef \
SENTRACE_MCP_TOKEN_NAME=production \
SENTRACE_MCP_TOKEN=snt_mcp_0123456789abcdef0123456789abcdef \
bin/rails sentrace:bootstrap
```

Or invoke the underlying idempotent ActiveRecord helpers directly:

```ruby
project, key = Sentrace::Project.ensure!(slug: "my-app", public_key: ENV["SENTRACE_PROJECT_PUBLIC_KEY"])
token_record, _ = Sentrace::McpToken.ensure!(name: "production", token: ENV["SENTRACE_MCP_TOKEN"])
```

## Reverse Proxy (TLS Termination) & OWASP ModSecurity CRS

### Forwarding `X-Forwarded-Proto: https` & `X-Forwarded-For` for `/sentrace/mcp`

`Sentrace::McpController` enforces HTTPS on all non-loopback hosts (`403 Forbidden` over plain HTTP), and `config.mcp_allowed_ips` / `config.internal_allowed_ips` evaluate `request.remote_ip`.

> **Security Note (Reverse Proxy Header Trust):** When Nginx and Puma run on the same host (`REMOTE_ADDR == 127.0.0.1`), `RequestSecurity.https_or_loopback?` trusts `request.ssl?` and `request.remote_ip`. Reverse proxies in front of Rails **must overwrite** (never blindly append or forward untrusted client-supplied) `X-Forwarded-Proto` and `X-Forwarded-For` headers. If your app sits behind a CDN, ALB, or multi-hop proxy, configure `config.action_dispatch.trusted_proxies` in Rails so `ActionDispatch::RemoteIp` strips untrusted hops and derives `request.remote_ip` accurately.

When TLS terminates at Nginx, AWS ALB, Alibaba SLB, or Fastly/Cloudflare in front of Puma, ensure the reverse proxy overwrites `X-Forwarded-Proto` and `X-Forwarded-For`:

```nginx
location /sentrace/ {
  proxy_pass http://puma_upstream;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $remote_addr;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

### OWASP ModSecurity Core Rule Set (CRS) Exclusions

Sentry v7 envelopes (`POST /sentrace/api/:project_id/envelope`) use `Content-Type: text/plain;charset=UTF-8` NDJSON bodies containing stack traces, file paths, and error strings (such as SQL or DOM snippets), and `/sentrace/mcp` exchanges JSON-RPC error payloads. Under OWASP ModSecurity CRS, these payloads commonly false-positive against:
- `920420` (Request content type `text/plain` not allowed by policy)
- `930120` (OS file access patterns matched on Ruby/Unix stack frame paths)
- `941100`–`941999` (`941xxx` XSS rules matched on HTML/JSX/DOM error messages)
- `942100`–`942999` (`942xxx` SQLi rules matched on ActiveRecord/SQL exception messages)

Add a targeted pre-evaluation exclusion for `/sentrace/api/` and `/sentrace/mcp`:

```apache
SecRule REQUEST_URI "@rx ^/sentrace/(?:api/|mcp(?:$|/))" \
  "id:1009001,phase:1,pass,nolog,\
   ctl:ruleRemoveById=920420,\
   ctl:ruleRemoveById=930120,\
   ctl:ruleRemoveById=941100-941999,\
   ctl:ruleRemoveById=942100-942999"
```

## Local MCP Server (`stdio`) & Environment Federation

`bin/rails generate sentrace:install` creates an executable `bin/sentrace-mcp` binstub (`chmod 0755`) that automatically `cd`s to the Rails root, prepends user Ruby version-manager shims (`~/.rbenv/shims`, `~/.local/share/mise/shims`, `~/.asdf/shims`), and isolates `stdout` (`fd 1`) **before** booting Rails so gem/initializer `puts` or logger output never corrupts MCP JSON-RPC framing (`bin/rails sentrace:mcp` is also available for interactive shell use):

```bash
./bin/sentrace-mcp
```

Workspace-local `.mcp.json` configuration (Claude Code / Cursor / Antigravity):

```json
{
  "mcpServers": {
    "sentrace": {
      "command": "./bin/sentrace-mcp"
    }
  }
}
```

Global IDE / daemon MCP configuration (`~/.gemini/config/mcp_config.json`, `~/.cursor/mcp.json`, Claude Desktop):

```json
{
  "mcpServers": {
    "sentrace": {
      "command": "/absolute/path/to/app/bin/sentrace-mcp"
    }
  }
}
```

Each remote Rails deployment (`staging`, `production`) exposes a stateless Streamable HTTP MCP endpoint at `POST /sentrace/mcp` (enforcing HTTPS on non-loopback hosts and constant-time `Authorization: Bearer <snt_mcp_token>` authentication). Configure `config.environments` locally to federate across deployments concurrently with per-environment timeouts and cross-environment fingerprint correlation:

```ruby
Sentrace.configure do |config|
  config.deployment_environment = ENV.fetch("SENTRACE_DEPLOYMENT_ENV", Rails.env)
  config.remote_timeout = 5.0

  config.environments = {
    local: { transport: :local },
    staging: {
      transport: :http,
      url: "https://staging.example.com/sentrace/mcp",
      token: ENV["SENTRACE_STAGING_MCP_TOKEN"],
      timeout: 3.0
    },
    production: {
      transport: :http,
      url: "https://errors.example.com/sentrace/mcp",
      token: ENV["SENTRACE_PROD_MCP_TOKEN"],
      timeout: 5.0
    }
  }
end
```

### Exposed MCP Capabilities
- **Tools**: `list_environments`, `list_projects`, `list_issues`, `get_issue`, `update_issue_status`, `list_events`, `get_event`, `get_error_trends`
- **Resources & Templates**: `sentrace://environments`, `sentrace://projects`, `sentrace://projects/{project_id}/issues`, `sentrace://issues/{issue_id}`, `sentrace://events/{event_id}`
- **Prompts**: `investigate_issue` (structured 8-step debugging workflow separating **Observed Evidence** from **Testable Hypotheses**)

## Retention, Storage Observability & Benchmarking

Run bounded batch retention via Rake, enqueue `Sentrace::RetentionCleanupJob` using any Rails ActiveJob adapter, or invoke `Sentrace::Retention::Cleaner.run!` directly from a native `sidekiq-cron` / scheduler worker (no Redis or ActiveJob required):

```bash
# Prune expired events and aged orphan issues
bin/rails sentrace:retention:cleanup

# Inspect PostgreSQL relation sizes, retention counts, and daily aggregates
bin/rails sentrace:stats

# Run the repeatable PostgreSQL storage, throughput, and latency benchmark
EVENTS=500 bin/rails sentrace:benchmark:storage
```

Programmatic retention cleanup (`Sentrace::Retention::Cleaner.run!`) returns an immutable `Sentrace::Retention::Cleaner::CleanupResult` (`Data.define`) struct:

```ruby
result = Sentrace::Retention::Cleaner.run!
```

| `CleanupResult` Attribute | Type | Description |
|---|---|---|
| `deleted_events_count` | `Integer` | Total expired `sentrace_events` rows deleted across all batches. |
| `deleted_orphan_issues_count` | `Integer` | Total zero-event `sentrace_issues` rows deleted past `orphan_issue_retention_period`. |
| `event_batches` | `Integer` | Number of `DELETE ... LIMIT` batches executed against `sentrace_events`. |
| `issue_batches` | `Integer` | Number of `DELETE ... LIMIT` batches executed against `sentrace_issues`. |
| `event_cutoff` | `Time` | UTC timestamp cutoff (`now - config.retention_period`) applied to `occurred_at`. |
| `orphan_issue_cutoff` | `Time` | UTC timestamp cutoff (`now - config.orphan_issue_retention_period`) applied to `last_seen_at`. |

Reference benchmark on PostgreSQL 18 / Ruby 3.3.13 (`EVENTS=500`, 8 stack frames + 8 breadcrumbs + tags/contexts per event):
- **Average PostgreSQL storage per event**: `~1.7 KB` (`~29.8%` B-tree index share across all 5 engine tables)
- **Envelope parse latency**: `~0.02 ms` (`SPEC.md` target `< 50 ms`)
- **Single-event persist latency**: `~0.8 ms` / `~1,300+ events/sec` (`SPEC.md` target `< 100 ms`)
- **Issue/event lookup & MCP `list_issues` latency**: `~0.3–1.6 ms` (`SPEC.md` targets `< 100 ms` / `< 500 ms`)
- **Batch retention deletion throughput**: `> 100,000 events/sec`

## Internal Administrative JSON API

`Sentrace::Engine` also mounts `/internal/projects`, `/internal/issues`, `/internal/events`, and `/internal/stats` for administration and integration testing, protected by default with MCP bearer tokens or a host-provided `config.internal_authenticator` policy.

### Built-in `/sentrace` Security Protections

- **Defensive response headers on all `/sentrace/*` routes**: `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`, and `Referrer-Policy: no-referrer`.
- **HTTPS + loopback peer verification on `/sentrace/mcp`**: Plain HTTP is permitted only when both `Host` and the peer IP (`remote_ip` / `REMOTE_ADDR`) are loopback (`127.0.0.0/8` / `::1`), blocking cleartext `Host: localhost` spoofing.
- **Cross-origin / DNS-rebinding & cookie-CSRF defense**: `/sentrace/mcp` and `/sentrace/internal/*` reject cross-origin `Origin`, `Origin: null`, and `Sec-Fetch-Site: cross-site` requests with `403 Forbidden`; state-changing cookie-authenticated requests on `/sentrace/internal/*` additionally require a verified same-origin `Origin`, `Content-Type: application/json`, or `X-CSRF-Token` / `X-Requested-With`.
- **Pre-body authentication & multi-item amplification caps**: `/sentrace/api/:project_id/envelope` validates `project_id` and header/query DSN credentials before reading `request.body`, enforces `max_envelope_size`, `max_events_per_envelope` (`10`), `max_envelope_items` (`50`), and JSON `max_nesting: 64`, and bounds breadcrumb timestamps and explicit fingerprints.
- **Recursive secret scrubbing & prompt-injection containment**: Redacts underscore and hyphenated credential keys (`api_key`, `api-key`, `private-key`, `secret-key`, bounded `ssn`/`otp`/`totp`), masks Bearer/Basic headers, URI passwords, JWTs, cloud/API tokens (`snt_mcp_`, `AKIA`, `ghp_`, `sk_live_`, `xoxb-`), PEM private keys, PostgreSQL dollar-quoted SQL literals, and Luhn PANs, and neutralizes embedded code fences inside MCP `investigate_issue` telemetry snapshots.

## Development Workflow (OpenSpec)

This repository uses [OpenSpec](https://github.com/Fission-AI/OpenSpec) (`spec-driven` schema):

- `SPEC.md` — Product vision, architecture, and MVP specification reference.
- `openspec/config.yaml` — Project-wide OpenSpec constraints, stack conventions, and workflow rules.
- `openspec/specs/` — Living source of truth for all implemented capabilities.
- `openspec/changes/archive/` — Historical record of completed specification-driven phases.

```bash
bin/setup
bundle exec rspec
bundle exec rubocop
openspec validate --all --strict --no-interactive
```

## License

Released under the [MIT License](LICENSE.txt).
