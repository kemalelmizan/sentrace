# Tasks

## 1. Sanitizer Precision (`allow_fields`, Session Key Matching, & `retain_user_fields`)

- [x] 1.1 Add `allow_fields` (default `[]`) and `retain_user_fields` (default `[]`) to `Sentrace::Configuration` with Array-of-String/Symbol validation, update `lib/sentrace/ingestion/sanitizer.rb` for `allow_fields` exemptions, auth-session key precision (`calibration_session_id` preserved), `user_id`/`userId` hashing, and bounded `retain_user_fields` (`<= 256` UTF-8 bytes, rejecting secret/IP keys, scrubbing Bearer/Luhn), and verify via RSpec in `spec/sentrace_spec.rb` and `spec/lib/sentrace/ingestion/sanitizer_spec.rb`
- [x] 1.2 Add `allowFields?: string[]` to `packages/sentrace/src/types.ts`, update `scrubUrl` in `packages/sentrace/src/dsn.ts` and callers in `client.ts`, `browser.ts`, and `rails.ts` so `*_session_id` domain keys are preserved while auth-session keys remain redacted and `allowFields` exemptions take effect, rebuild `packages/sentrace`, and verify via `rtk npm --prefix packages/sentrace test`

## 2. Float & Unit-Suffix Message Fingerprinting

- [x] 2.1 Update `Sentrace::Issues::Fingerprint.normalize_message` in `lib/sentrace/issues/fingerprint.rb` to normalize floating-point numbers and numeric+unit tokens (`3.45s`, `250ms`, `12.5%`, `10MB`) to a canonical `<num>` placeholder prior to integer normalization, and verify via RSpec in `spec/lib/sentrace/issues/fingerprint_spec.rb`

## 3. Declarative CI/CD Credential Bootstrap & Reverse-Proxy / WAF Docs

- [x] 3.1 Implement `Sentrace::Project.ensure!(slug:, name: nil, public_key: nil)` (`app/models/sentrace/project.rb`) and `Sentrace::McpToken.ensure!(name: "default", token: nil)` (`app/models/sentrace/mcp_token.rb`) with entropy/revocation/cross-project guards, and verify via RSpec in `spec/models/sentrace/project_spec.rb` and `spec/models/sentrace/mcp_token_spec.rb`
- [x] 3.2 Add `Sentrace::Bootstrapper` (`lib/sentrace/bootstrapper.rb`), built-in `bin/rails sentrace:bootstrap` (`lib/tasks/sentrace_bootstrap.rake`), and updated `sentrace_setup.rake.tt` + `initializer.rb.tt` templates reading `SENTRACE_PROJECT_SLUG`, `SENTRACE_PROJECT_PUBLIC_KEY`, `SENTRACE_MCP_TOKEN_NAME`, and `SENTRACE_MCP_TOKEN` idempotently without echoing CI secrets, document reverse-proxy `X-Forwarded-Proto: https` and OWASP ModSecurity CRS exclusions (`920420`, `930120`, `941xxx`, `942xxx`) in `README.md`, and verify via RSpec in `spec/tasks/sentrace_bootstrap_rake_spec.rb` and `spec/generators/sentrace/install_generator_spec.rb`

## 4. Cross-Rails & Lint Verification

- [x] 4.1 Verify zero `rubocop-rails-omakase` offenses (`rtk bundle exec rubocop`), green Node SDK tests (`rtk npm --prefix packages/sentrace test`), and green RSpec suites under both Rails 8.1 (`rtk bundle exec rspec`) and Rails 6.1 (`BUNDLE_GEMFILE=gemfiles/rails_6_1.gemfile rtk bundle exec rspec`)

## Workflow follow-up

- Sync delta specs and archive `phase-8-sanitizer-fingerprinting-and-bootstrap` into `openspec/changes/archive/` once all tasks and strict validation pass.
