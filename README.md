# Sentrace

**Sentry-compatible error tracking for Ruby on Rails, with a federated Model Context Protocol (MCP) interface.**

Sentrace is a self-hosted, isolated Rails Engine (`Sentrace::Engine`) backed by PostgreSQL. It ingests application errors via the Sentry envelope protocol (`sentry-ruby`), normalizes and deduplicates events, groups related occurrences into deterministic issues, and exposes errors across local, staging, and production environments through local `stdio` and remote Streamable HTTP MCP transports.

See [SPEC.md](SPEC.md) for the full product specification and architecture.

## Requirements

- Ruby `>= 3.2` (local development standardized on `3.3.13`)
- Rails `>= 7.1`
- PostgreSQL `>= 15`

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
bin/rails sentrace:projects
bin/rails "sentrace:projects:create[my-app]"
bin/rails "sentrace:projects:rotate_key[my-app]"
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
