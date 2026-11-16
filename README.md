# Sentrace

**Sentry-compatible error tracking for Ruby on Rails, with a federated Model Context Protocol (MCP) interface.**

Sentrace is a self-hosted, isolated Rails Engine (`Sentrace::Engine`) backed solely by PostgreSQL. It ingests application errors via the Sentry v7 envelope protocol (`sentry-ruby`), sanitizes sensitive fields before persistence, normalizes and deduplicates events, groups related occurrences into deterministic fingerprinted issues, and exposes issues, events, and trends across `local`, `staging`, and `production` environments through local `stdio` and remote Streamable HTTP MCP transports.

See [SPEC.md](SPEC.md) for the complete product specification and architecture.

## Architecture

```text
Rails application (sentry-ruby)
        |
        | POST /sentrace/api/:project_id/envelope (raw or gzip)
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
- Rails `>= 7.1`
- PostgreSQL `>= 15`
- Official [`mcp`](https://rubygems.org/gems/mcp) Ruby SDK (`~> 1.0`)
- Client SDK compatibility: verified against official [`sentry-ruby`](https://github.com/getsentry/sentry-ruby) `5.28.x` (`5.28.1` pinned in integration specs; Envelope protocol v7, raw & `gzip` transport, exceptions, messages, breadcrumbs, stack traces, and safe zero-write discarding of unsupported performance/session items)

## Host Application Installation

```bash
bundle add sentrace
bin/rails generate sentrace:install
bin/rails db:migrate
bin/rails sentrace:setup
```

Configure `sentry-ruby` with the generated DSN:

```ruby
Sentry.init do |config|
  config.dsn = ENV.fetch("SENTRY_DSN")
  config.environment = Rails.env
  config.release = ENV["APP_RELEASE"]
end
```

## Configuration Reference

Configure Sentrace in `config/initializers/sentrace.rb`:

| Option | Default | Description |
|---|---|---|
| `enabled` | `true` | Enable or disable Sentrace envelope ingestion (`202 Accepted` no-op when `false`). |
| `deployment_environment` | `Rails.env` | Environment attribution label stamped on remote `/sentrace/mcp` responses. |
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
