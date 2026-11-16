# Tasks

## 1. Gemspec, Boot, and Migration Floor (`Rails >= 6.1`, `pg >= 1.4`, `PostgreSQL >= 12`)

- [x] 1.1 Relax `sentrace.gemspec` (`rails >= 6.1, < 9.0`, `pg >= 1.4, < 2.0`), require stdlib `logger` before ActiveSupport in `lib/sentrace.rb`, and update `README.md` and `openspec/config.yaml` stack floors, verified with `rtk bundle exec rspec spec/sentrace_spec.rb`
- [x] 1.2 Update all five engine migrations in `db/migrate/*.rb` from `ActiveRecord::Migration[7.1]` and `t.timestamptz` to `ActiveRecord::Migration[6.1]` and `t.column :<col>, :timestamptz`, and assert migration compatibility and PG 12+ SQL invariants in `spec/db/schema_spec.rb` and `spec/generators/install_generator_spec.rb`, verified with `rtk bundle exec rspec spec/db/schema_spec.rb spec/generators/sentrace/install_generator_spec.rb`

## 2. Cross-Version ActiveRecord Enums and Rack 2.2 / `Cache-Control` Controllers

- [x] 2.1 Implement `sentrace_enum` in `app/models/sentrace/application_record.rb` and migrate `Sentrace::Issue` (`status`, `level`) and `Sentrace::Event` (`level`) with cross-version ActiveModel enum validation specs, verified with `rtk bundle exec rspec spec/models/sentrace/issue_spec.rb spec/models/sentrace/event_spec.rb`
- [x] 2.2 Enforce `Cache-Control: no-store` on `Sentrace::ApplicationController` (and `McpController#write_rack_response`), replace `:content_too_large` with numeric `413` in `IngestionController`, and replace `:unprocessable_content` with numeric `422` in `Internal::BaseController` and `Internal::ProjectsController`, verified with `rtk bundle exec rspec spec/requests/`

## 3. Multi-Rails (`6.1` + `Rack 2.2` and `8.x` + `Rack 3.x`) Verification & CI Matrix

- [x] 3.1 Guard Rails 7.1+ configuration options in `spec/dummy/config/**` and `spec/rails_helper.rb`, add `gemfiles/rails_6_1.gemfile` (`rails ~> 6.1.7`, `rack ~> 2.2.9`, `pg >= 1.4`, `rspec-rails ~> 6.1`), and expand `.github/workflows/ci.yml` across Rails `6.1`/`8.1` and PostgreSQL `12`/`16`, verified by running the full RSpec suite under both `Gemfile` and `BUNDLE_GEMFILE=gemfiles/rails_6_1.gemfile` plus `rtk bundle exec rubocop`

## Workflow follow-up

- Sync delta specs into `openspec/specs/`, run `rtk openspec validate --all --strict --no-interactive`, and archive `phase-7-rails61-rack22-pg12-compatibility`.
