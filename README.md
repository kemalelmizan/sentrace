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
        +---> Local MCP Server (stdio: bin/rails sentrace:mcp)
        |         \
        |          +---> EnvironmentRouter ---> Remote Streamable HTTP (/sentrace/mcp on staging & production)
        |
        +---> Retention::Cleaner (ActiveJob / Rake) & StorageStats
```

## Requirements

- Ruby `>= 3.2` (local development standardized on `3.3.13`)
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

> **Important (`<head>` ordering):** Render `<%= sentrace_meta_tags %>` inside `<head>` **before** any synchronous `<script>`, `javascript_pack_tag`, `javascript_include_tag`, or `yield(:head)` tags in `app/views/layouts/application.html.erb` (with `config.frontend_dsn` set in `config/initializers/sentrace.rb`). Synchronous packs executing in `<head>` read `<meta name="sentrace-*">` immediately during `Sentrace.init()`.

```erb
<head>
  <%= sentrace_meta_tags %>
  <%= javascript_pack_tag "application" %>
  <%= yield(:head) %>
</head>
```

Initialize in `app/javascript/application.js`:

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
| `excluded_exceptions` | Standard Rails 404/400 classes | Exceptions ignored by unhandled middleware/job integrations (explicit `capture_exception` still captures). |
| `before_send` | `nil` | Optional callable `->(raw_event_hash, hint) { hash_or_nil }` for mutating or dropping native Ruby events. |
| `breadcrumbs_logger` | `[]` | Safe instrumentation loggers (`%i[active_support_logger http_logger]`, omitting SQL binds and HTTP bodies). |
| `async_queue_size` | `256` | Bounded non-blocking `SizedQueue` capacity for transaction-isolated, fork-safe background persistence. |
| `capture_dispatch` | `:async` | `:async` (`SizedQueue` worker thread) or `:inline` (isolated from open/aborted caller transactions). |
| `frontend_dsn` | `nil` | Public DSN rendered by `sentrace_meta_tags` (strips any accidental secret key). |
| `release` | `ENV["APP_RELEASE"]` | Release label rendered by `sentrace_meta_tags`. |
| `cors_allowed_origins` | `[]` | Allowed browser `Origin`s (`Array` of origins or `"*"`) for `/api/:project_id/envelope`. |
| `retention_period` | `30.days` | How long normalized `sentrace_events` rows are retained before batch pruning. |
| `orphan_issue_retention_period` | `7.days` | Grace period before deleting `sentrace_issues` with zero remaining events. |
| `retention_batch_size` | `1000` | Maximum rows deleted per SQL statement during retention cleanup. |
| `max_envelope_size` | `1.megabyte` | Pre-parse compressed and decompressed envelope byte ceiling (`413` if exceeded). |
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
| `remote_timeout` | `5.0` | Default timeout (seconds) for remote `:http` MCP federation requests. |
| `environments` | `{ local: { transport: :local } }` | Map of `:local` and `:http` MCP environments for federation. |
| `internal_authenticator` | `nil` | Optional callable `->(request) { boolean }` for `/sentrace/internal/*` routes (defaults to MCP bearer token auth). |

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

### Forwarding `X-Forwarded-Proto: https` for `/sentrace/mcp`

`Sentrace::McpController` enforces HTTPS on all non-loopback hosts (`403 Forbidden` over plain HTTP). When TLS terminates at Nginx, AWS ALB, Alibaba SLB, or Fastly/Cloudflare in front of Puma, ensure the reverse proxy forwards `X-Forwarded-Proto: https` so Rails `request.ssl?` evaluates to `true`:

```nginx
location /sentrace/ {
  proxy_pass http://puma_upstream;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
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

Run the standalone Sentrace MCP server over `stdio` (no running Rails web server required):

```bash
bin/rails sentrace:mcp
```

Example `.mcp.json` configuration (Claude Code / Cursor / Antigravity):

```json
{
  "mcpServers": {
    "sentrace": {
      "command": "bin/rails",
      "args": ["sentrace:mcp"]
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

Run bounded batch retention via Rake or enqueue `Sentrace::RetentionCleanupJob` using any Rails ActiveJob adapter (no Redis required):

```bash
# Prune expired events and aged orphan issues
bin/rails sentrace:retention:cleanup

# Inspect PostgreSQL relation sizes, retention counts, and daily aggregates
bin/rails sentrace:stats

# Run the repeatable PostgreSQL storage, throughput, and latency benchmark
EVENTS=500 bin/rails sentrace:benchmark:storage
```

Reference benchmark on PostgreSQL 18 / Ruby 3.3.13 (`EVENTS=500`, 8 stack frames + 8 breadcrumbs + tags/contexts per event):
- **Average PostgreSQL storage per event**: `~1.7 KB` (`~29.8%` B-tree index share across all 5 engine tables)
- **Envelope parse latency**: `~0.02 ms` (`SPEC.md` target `< 50 ms`)
- **Single-event persist latency**: `~0.8 ms` / `~1,300+ events/sec` (`SPEC.md` target `< 100 ms`)
- **Issue/event lookup & MCP `list_issues` latency**: `~0.3–1.6 ms` (`SPEC.md` targets `< 100 ms` / `< 500 ms`)
- **Batch retention deletion throughput**: `> 100,000 events/sec`

## Internal Administrative JSON API

`Sentrace::Engine` also mounts `/internal/projects`, `/internal/issues`, `/internal/events`, and `/internal/stats` for administration and integration testing, protected by default with MCP bearer tokens or a host-provided `config.internal_authenticator` policy.

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
