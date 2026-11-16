# Sentrace

**Sentry-compatible error tracking for Ruby on Rails, with a federated Model Context Protocol (MCP) interface.**

Sentrace is a self-hosted, isolated Rails Engine (`Sentrace::Engine`) backed by PostgreSQL. It ingests application errors via the Sentry envelope protocol (`sentry-ruby`), normalizes and deduplicates events, groups related occurrences into deterministic issues, and exposes errors across local, staging, and production environments through local `stdio` and remote Streamable HTTP MCP transports.

See [SPEC.md](SPEC.md) for the full product specification and architecture.

## Requirements

- Ruby `>= 3.2` (local development standardized on `3.3.13`)
- Rails `>= 7.1`
- PostgreSQL `>= 15`
- Client SDK compatibility: verified against official [`sentry-ruby`](https://github.com/getsentry/sentry-ruby) `5.28.x` (`5.28.1` pinned in integration specs; Envelope protocol v7, raw & `gzip` transport, exceptions, messages, breadcrumbs, stack traces, and safe discarding of unsupported performance/session items)

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

## Project & Credential Management

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

Each remote Rails deployment (`staging`, `production`) exposes an authenticated Streamable HTTP MCP endpoint at `POST /sentrace/mcp` (requiring HTTPS on non-loopback hosts and `Authorization: Bearer <snt_mcp_token>`). Configure your local initializer (`config/initializers/sentrace.rb`) to federate across environments concurrently:

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

Example MCP client configuration (`.mcp.json` / Claude Code / Cursor / Antigravity):

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

## Development Workflow (OpenSpec)

This repository uses [OpenSpec](https://github.com/Fission-AI/OpenSpec) (`spec-driven` schema) for specification-driven development:

- `SPEC.md` — Product vision, architecture, and MVP specification reference.
- `openspec/config.yaml` — Project-wide OpenSpec constraints, stack conventions, and workflow rules.
- `openspec/specs/` — Living source of truth for implemented capabilities (populated as changes are archived).
- `openspec/changes/` — Active change proposals (`proposal.md`, `specs/`, `design.md`, `tasks.md`).

Useful OpenSpec commands:

```bash
openspec list
openspec validate --all --strict --no-interactive
```

## Local Setup

```bash
bin/setup
bundle exec rspec
bundle exec rubocop
```

## License

Released under the [MIT License](LICENSE.txt).
