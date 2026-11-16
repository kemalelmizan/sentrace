# engine-configuration Specification (Delta)

## MODIFIED Requirements

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

### Requirement: Host installation generator
Running `bin/rails generate sentrace:install` SHALL create `config/initializers/sentrace.rb`, mount the engine in `config/routes.rb` idempotently, copy `ActiveRecord::Migration[6.1]` migrations using `:timestamptz` columns into `db/migrate/`, install an idempotent `sentrace:setup` bootstrap task honoring CI/CD environment variables, and print setup instructions.

#### Scenario: Fresh installation in a host Rails application
- **GIVEN** a host Rails `6.1`, `7.x`, or `8.x` application without existing Sentrace setup
- **WHEN** the developer runs `bin/rails generate sentrace:install`
- **THEN** the initializer is created, the engine route mount is added, `ActiveRecord::Migration[6.1]` migrations using `:timestamptz` columns are copied, and SDK setup instructions are printed

#### Scenario: Re-running the install generator is idempotent
- **GIVEN** a host Rails application where `sentrace:install` has already been run
- **WHEN** the developer runs `bin/rails generate sentrace:install` again
- **THEN** duplicate route mounts and duplicate migration copies are not created

#### Scenario: Generated sentrace:setup task idempotently seeds credentials from environment variables
- **GIVEN** `SENTRACE_PROJECT_SLUG`, `SENTRACE_PROJECT_PUBLIC_KEY`, `SENTRACE_MCP_TOKEN_NAME`, and `SENTRACE_MCP_TOKEN` set in the environment
- **WHEN** `bin/rails sentrace:setup` is executed across repeated container boots
- **THEN** the project, pinned DSN public key, and digest-only MCP bearer token are provisioned once without rotating credentials or printing the raw environment MCP token
