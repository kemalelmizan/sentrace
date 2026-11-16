# engine-configuration Specification

## ADDED Requirements

### Requirement: Multi-generation Rails, Rack, pg, and PostgreSQL compatibility floor
The engine gem SHALL support host applications running `Ruby >= 3.2.0`, `Rails >= 6.1, < 9.0`, `Rack >= 2.2`, `pg >= 1.4, < 2.0`, and `PostgreSQL >= 12`, initializing cleanly without `NameError`, `NoMethodError`, or `ArgumentError` across Rails `6.1`, `7.x`, and `8.x`.

#### Scenario: Booting Sentrace in a Rails 6.1 and Rack 2.2 host on Ruby 3.3
- **GIVEN** a host application running `Ruby >= 3.2`, `Rails 6.1.x`, `Rack 2.2.x`, and `pg >= 1.4`
- **WHEN** `sentrace` is required and the Rails application initializes
- **THEN** stdlib dependencies load cleanly and `Sentrace::Engine` boots without `Logger`, enum, or middleware errors

#### Scenario: Gemspec enforces relaxed Rails and pg dependency bounds
- **WHEN** `sentrace.gemspec` runtime dependencies are inspected
- **THEN** `rails` allows `>= 6.1, < 9.0`, `pg` allows `>= 1.4, < 2.0`, `mcp` requires `~> 1.0`, and `required_ruby_version` is `>= 3.2.0`

## MODIFIED Requirements

### Requirement: Host installation generator
Running `bin/rails generate sentrace:install` in a host application SHALL create `config/initializers/sentrace.rb`, mount the engine in `config/routes.rb` idempotently, copy Rails `6.1`-compatible engine migrations (`ActiveRecord::Migration[6.1]` using `t.column ..., :timestamptz`) into `db/migrate/`, install a project bootstrap task, and output backend and frontend setup instructions.

#### Scenario: Fresh installation in a host Rails application
- **GIVEN** a host Rails `6.1`, `7.x`, or `8.x` application without existing Sentrace setup
- **WHEN** the developer runs `bin/rails generate sentrace:install`
- **THEN** the initializer is created, the engine route mount is added, `ActiveRecord::Migration[6.1]` migrations using `:timestamptz` columns are copied, and SDK setup instructions are printed

#### Scenario: Re-running the install generator is idempotent
- **GIVEN** a host Rails application where `sentrace:install` has already been run
- **WHEN** the developer runs `bin/rails generate sentrace:install` again
- **THEN** duplicate route mounts and duplicate migration copies are not created
