# engine-configuration Specification

## Purpose
Defines how a host Rails application installs, mounts, and configures Sentrace as an isolated engine, including default payload limits, retention settings, sensitive field redaction rules, and MCP environment definitions.

## Requirements

### Requirement: Isolated engine namespace and host independence
The engine SHALL operate in an isolated namespace with the `sentrace_` database table prefix and MUST NOT require any host user authentication library, frontend asset pipeline, or external cache/queue store such as Redis.

#### Scenario: Host application boots Sentrace without authentication or frontend gems
- **GIVEN** a host Rails application running PostgreSQL without Devise, Redis, or frontend asset gems
- **WHEN** the host application boots with Sentrace mounted
- **THEN** the engine initializes cleanly and scopes all engine-owned table names under the `sentrace_` prefix

### Requirement: Runtime configuration defaults and overrides
The system SHALL expose a block-based configuration interface with safe defaults for enablement (`true`), event retention (`30 days`), orphan issue retention, envelope size (`1 MB`), message size (`4 KB`), stack frames (`50`), breadcrumbs (`20`), tags (`32`, keys `64 B`, values `256 B`), and context entries (`16`, serialized `8 KB`), and MUST allow host applications to override each value.

#### Scenario: Default configuration values are applied when unconfigured
- **WHEN** Sentrace boots without custom overrides
- **THEN** `enabled` is `true`, retention is `30 days`, envelope limit is `1 MB`, stack frame limit is `50`, breadcrumb limit is `20`, tag limit is `32`, and context limit is `16` entries (`8 KB`)

#### Scenario: Host initializer overrides payload and retention settings
- **GIVEN** a host initializer configuring `retention_period = 14.days` and `max_breadcrumbs = 10`
- **WHEN** configuration is read at runtime
- **THEN** the overridden values take effect while unspecified limits keep their defaults

#### Scenario: Invalid numeric bounds are rejected
- **WHEN** a host application configures a non-positive payload limit or retention period
- **THEN** configuration validation raises a descriptive configuration error

### Requirement: Sensitive field redaction and custom sanitizer configuration
The configuration SHALL provide default `redact_fields` (`password`, `token`, `authorization`, `cookie`, `credit_card`), `allow_fields` (`[]`), and `retain_user_fields` (`[]`), SHALL allow host applications to extend or override each list or register a callable `sanitizer`, and MUST reject non-Array field lists with `Sentrace::ConfigurationError`.

#### Scenario: Default redaction fields are present out of the box
- **WHEN** configuration is initialized with defaults
- **THEN** `redact_fields` includes `password`, `token`, `authorization`, `cookie`, and `credit_card`, while `allow_fields` and `retain_user_fields` default to empty arrays (`[]`)

#### Scenario: Host registers a callable custom sanitizer
- **WHEN** a host application assigns a callable object as a custom sanitizer
- **THEN** configuration retains the callable for invocation prior to event persistence

#### Scenario: Configuring allow_fields and retain_user_fields with type validation
- **WHEN** a host configures `allow_fields = %w[token_present token_expires_in]` and `retain_user_fields = %w[id email username]`
- **THEN** `Sentrace.configure` retains both lists and raises `Sentrace::ConfigurationError` if either setting is assigned a non-Array or contains non-String/non-Symbol elements

### Requirement: Federated MCP environment configuration
The configuration SHALL accept logical environment definitions mapping identifiers to `:local` database access or remote `:http` MCP endpoints (URL, bearer token, timeout), defaulting to `:local` and providing a positive numeric `remote_ping_timeout` (default `2.5` seconds). Remote `:http` entries with `nil` or blank `url` or `token` MUST NOT raise `Sentrace::ConfigurationError` at boot, while non-blank `:http` URLs MUST validate syntax and enforce HTTPS on non-loopback hosts.

#### Scenario: Local and remote environments are configured
- **WHEN** a host configures `local` (`transport: :local`) alongside `staging` and `production` (`transport: :http` with URLs and tokens)
- **THEN** the environment registry exposes each logical identifier with its transport type and timeout settings without leaking raw tokens in inspect strings

#### Scenario: Non-HTTPS remote MCP URL is rejected for non-local hosts
- **WHEN** a remote `:http` environment is configured with a `http://` URL pointing to a non-loopback host
- **THEN** configuration validation rejects the insecure URL

#### Scenario: Remote HTTP environment with unset URL or token boots cleanly without raising ConfigurationError
- **WHEN** a host initializer registers `staging: { transport: :http, url: ENV["SENTRACE_STAGING_MCP_URL"], token: ENV["SENTRACE_STAGING_MCP_TOKEN"] }` while those environment variables are unset or blank
- **THEN** `Sentrace.configure` succeeds without raising `Sentrace::ConfigurationError` and retains the `:staging` definition for `"unconfigured"` reporting

### Requirement: Host installation generator
Running `bin/rails generate sentrace:install` SHALL create `config/initializers/sentrace.rb` (defaulting `enabled` to `false` in test unless `SENTRACE_ENABLED=true` and prefilling `project_slug`), generate an executable `bin/sentrace-mcp` (`0755`) binstub, mount the engine idempotently, copy `ActiveRecord::Migration[6.1]` `:timestamptz` migrations, install an idempotent `sentrace:setup` task, and print native-first `Sentrace`, `sentrace_meta_tags`, and `bin/sentrace-mcp` instructions.

#### Scenario: Fresh installation in a host Rails application
- **GIVEN** a host Rails `6.1`, `7.x`, or `8.x` application without existing Sentrace setup
- **WHEN** the developer runs `bin/rails generate sentrace:install`
- **THEN** the initializer (with `!Rails.env.test?` default enablement and `project_slug`), executable `bin/sentrace-mcp` (`0755`), engine route mount, `ActiveRecord::Migration[6.1]` `:timestamptz` migrations, and `sentrace:setup` task are created, and native `Sentrace` + `sentrace_meta_tags` + `bin/sentrace-mcp` instructions are printed

#### Scenario: Re-running the install generator is idempotent
- **GIVEN** a host Rails application where `sentrace:install` has already been run
- **WHEN** the developer runs `bin/rails generate sentrace:install` again
- **THEN** duplicate route mounts and duplicate migration copies are not created

#### Scenario: Generated sentrace:setup task idempotently seeds credentials from environment variables
- **GIVEN** `SENTRACE_PROJECT_SLUG`, `SENTRACE_PROJECT_PUBLIC_KEY`, `SENTRACE_MCP_TOKEN_NAME`, and `SENTRACE_MCP_TOKEN` set in the environment
- **WHEN** `bin/rails sentrace:setup` is executed across repeated container boots
- **THEN** the project, pinned DSN public key, and digest-only MCP bearer token are provisioned once without rotating credentials or printing the raw environment MCP token

### Requirement: Deployment environment attribution label
`Sentrace::Configuration` SHALL provide a `deployment_environment` setting (defaulting to `Rails.env`) that identifies the deployment's logical environment name when answering remote Streamable HTTP MCP requests.

#### Scenario: Custom deployment_environment stamps remote MCP responses
- **GIVEN** a deployment configured with `config.deployment_environment = "staging-eu"`
- **WHEN** that deployment serves MCP queries over `/sentrace/mcp`
- **THEN** returned projects, issues, events, and trends carry `"environment" => "staging-eu"`

### Requirement: Retention batch size and host internal authenticator configuration
`Sentrace::Configuration` SHALL provide a positive integer `retention_batch_size` setting (defaulting to `1000`) and an optional callable `internal_authenticator` setting (defaulting to `nil`) for delegating `/sentrace/internal` authorization to the host Rails application.

#### Scenario: Validating retention_batch_size and internal_authenticator
- **WHEN** a host application configures `retention_batch_size = 500` and a callable `internal_authenticator = ->(request) { ... }`
- **THEN** `Sentrace.configure` accepts both settings and raises `Sentrace::ConfigurationError` if `retention_batch_size <= 0` or `internal_authenticator` does not respond to `#call`

### Requirement: Frontend DSN, release, and CORS allowed origins configuration
`Sentrace::Configuration` SHALL provide `frontend_dsn` (defaulting to `nil`), `release` (defaulting to `ENV["APP_RELEASE"]`), and `cors_allowed_origins` (defaulting to `[]`, accepting an Array of origin strings or `"*"`) for browser error ingestion and Rails layout helpers.

#### Scenario: Configuring cors_allowed_origins and frontend_dsn
- **WHEN** a host application configures `cors_allowed_origins = ["https://app.example.com"]`, `frontend_dsn = "https://pub@api.example.com/sentrace/1"`, and `release = "2026.11.16"`
- **THEN** `Sentrace.configure` validates the origin list and exposes the settings while rejecting non-String/non-Array `cors_allowed_origins` with `Sentrace::ConfigurationError`

### Requirement: Multi-generation Rails, Rack, pg, and PostgreSQL compatibility floor
The engine gem SHALL support host applications running `Ruby >= 3.2.0`, `Rails >= 6.1, < 9.0`, `Rack >= 2.2`, `pg >= 1.4, < 2.0`, and `PostgreSQL >= 12`, initializing cleanly without `NameError`, `NoMethodError`, or `ArgumentError` across Rails `6.1`, `7.x`, and `8.x`.

#### Scenario: Booting Sentrace in a Rails 6.1 and Rack 2.2 host on Ruby 3.3
- **GIVEN** a host application running `Ruby >= 3.2`, `Rails 6.1.x`, `Rack 2.2.x`, and `pg >= 1.4`
- **WHEN** `sentrace` is required and the Rails application initializes
- **THEN** stdlib dependencies load cleanly and `Sentrace::Engine` boots without `Logger`, enum, or middleware errors

#### Scenario: Gemspec enforces relaxed Rails and pg dependency bounds
- **WHEN** `sentrace.gemspec` runtime dependencies are inspected
- **THEN** `rails` allows `>= 6.1, < 9.0`, `pg` allows `>= 1.4, < 2.0`, `mcp` requires `~> 1.0`, and `required_ruby_version` is `>= 3.2.0`

### Requirement: Native Ruby capture client and async dispatch configuration
`Sentrace::Configuration` SHALL provide `project_slug` (`nil`), `project_id` (`nil`), `capture_unhandled_exceptions` (`true` when a target project is configured, `false` otherwise unless set explicitly), `sample_rate` (`1.0`, `0.0..1.0`), `excluded_exceptions`, `before_send` (`nil` or `#call`), `breadcrumbs_logger` (`[]`), `async_queue_size` (`256`), and `capture_dispatch` (`:async` or `:inline`), rejecting invalid values with `Sentrace::ConfigurationError`.

#### Scenario: Default capture_unhandled_exceptions derives from project_slug or project_id unless overridden
- **WHEN** `Sentrace::Configuration.new` is inspected without a target project, then configured with `project_slug = "monolith"`, and finally configured with `capture_unhandled_exceptions = false`
- **THEN** `capture_unhandled_exceptions` evaluates to `false` initially, `true` once `project_slug` is set, and `false` when explicitly disabled

#### Scenario: Validating sample_rate, before_send, breadcrumbs_logger, async_queue_size, and capture_dispatch
- **WHEN** a host application configures an out-of-range `sample_rate` (`1.5`), a non-callable `before_send`, an unsupported `breadcrumbs_logger` symbol, a non-positive `async_queue_size`, or an unknown `capture_dispatch` mode
- **THEN** `Sentrace.configure` raises `Sentrace::ConfigurationError` for each invalid setting
