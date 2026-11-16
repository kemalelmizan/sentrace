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
The configuration SHALL provide a default list of redacted field names (`password`, `token`, `authorization`, `cookie`, `credit_card`) and SHALL allow host applications to extend the redaction list or register a callable custom sanitizer.

#### Scenario: Default redaction fields are present out of the box
- **WHEN** configuration is initialized with defaults
- **THEN** the redaction list includes `password`, `token`, `authorization`, `cookie`, and `credit_card`

#### Scenario: Host registers a callable custom sanitizer
- **WHEN** a host application assigns a callable object as a custom sanitizer
- **THEN** configuration retains the callable for invocation prior to event persistence

### Requirement: Federated MCP environment configuration
The configuration SHALL accept logical environment definitions mapping environment identifiers to either local database access (`:local`) or remote HTTP MCP endpoints (`:http` with URL, bearer token, and request timeout), defaulting to a `:local` environment entry.

#### Scenario: Local and remote environments are configured
- **WHEN** a host configures `local` (`transport: :local`) alongside `staging` and `production` (`transport: :http` with URLs and tokens)
- **THEN** the environment registry exposes each logical identifier with its transport type and timeout settings without leaking raw tokens in inspect strings

#### Scenario: Non-HTTPS remote MCP URL is rejected for non-local hosts
- **WHEN** a remote `:http` environment is configured with a `http://` URL pointing to a non-loopback host
- **THEN** configuration validation rejects the insecure URL

### Requirement: Host installation generator
Running `bin/rails generate sentrace:install` in a host application SHALL create `config/initializers/sentrace.rb`, mount the engine in `config/routes.rb` idempotently, copy engine migrations into the host `db/migrate/` directory, install a project bootstrap task, and output both backend `Sentry.init` and frontend `sentrace` setup instructions.

#### Scenario: Fresh installation in a host Rails application
- **GIVEN** a host Rails application without existing Sentrace setup
- **WHEN** the developer runs `bin/rails generate sentrace:install`
- **THEN** the initializer is created, the engine route mount is added, engine migrations are copied, and backend plus frontend SDK setup instructions are printed

#### Scenario: Re-running the install generator is idempotent
- **GIVEN** a host Rails application where `sentrace:install` has already been run
- **WHEN** the developer runs `bin/rails generate sentrace:install` again
- **THEN** duplicate route mounts and duplicate migration copies are not created

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
