## MODIFIED Requirements

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
