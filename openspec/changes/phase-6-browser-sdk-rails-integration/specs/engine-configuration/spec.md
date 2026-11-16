# engine-configuration Specification

## ADDED Requirements

### Requirement: Frontend DSN, release, and CORS allowed origins configuration
`Sentrace::Configuration` SHALL provide `frontend_dsn` (defaulting to `nil`), `release` (defaulting to `ENV["APP_RELEASE"]`), and `cors_allowed_origins` (defaulting to `[]`, accepting an Array of origin strings or `"*"`) for browser error ingestion and Rails layout helpers.

#### Scenario: Configuring cors_allowed_origins and frontend_dsn
- **WHEN** a host application configures `cors_allowed_origins = ["https://app.example.com"]`, `frontend_dsn = "https://pub@api.example.com/sentrace/1"`, and `release = "2026.11.16"`
- **THEN** `Sentrace.configure` validates the origin list and exposes the settings while rejecting non-String/non-Array `cors_allowed_origins` with `Sentrace::ConfigurationError`

## MODIFIED Requirements

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
