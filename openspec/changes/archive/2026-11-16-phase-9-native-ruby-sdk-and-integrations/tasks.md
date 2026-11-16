# Tasks

## 1. Configuration & Event Mechanism Normalization

- [x] 1.1 Extend `Sentrace::Configuration` with `project_slug`, `project_id`, `capture_unhandled_exceptions`, `sample_rate`, `excluded_exceptions`, `before_send`, `breadcrumbs_logger`, `async_queue_size`, and `capture_dispatch` plus validation, preserve optional `exception.mechanism` in `EventNormalizer`, and verify `spec/lib/sentrace/configuration_spec.rb` and `spec/lib/sentrace/ingestion/event_normalizer_spec.rb` pass

## 2. Native Ruby Client, Scope API, & Transaction/Fork-Safe Dispatcher

- [x] 2.1 Implement `Sentrace::Breadcrumb`, `Sentrace::Scope`, `Sentrace::EventBuilder`, `Sentrace::AsyncWorker` (`SizedQueue` overflow protection, `Process.pid` fork respawn, `with_connection`, `flush` + `at_exit`), `Sentrace::CaptureDispatcher` (`:async` and transaction-isolated `:inline`), and top-level `Sentrace.*` methods, and verify `spec/lib/sentrace/ruby_sdk_spec.rb` and `spec/integration/transaction_and_fork_safety_spec.rb` pass

## 3. Safe Breadcrumb Loggers (`active_support_logger` & `http_logger`)

- [x] 3.1 Implement `Sentrace::Breadcrumbs::ActiveSupportLogger` and `Sentrace::Breadcrumbs::HttpLogger` (without logging SQL bind values, HTTP bodies, or internal Sentrace calls), wire activation via `config.breadcrumbs_logger`, and verify breadcrumb logger specs in `spec/lib/sentrace/ruby_sdk_spec.rb` pass

## 4. Rack/Rails, Sidekiq, & ActiveJob Integrations + `SentryTransport`

- [x] 4.1 Implement `ExceptionDeduplicator`, `RackMiddleware`, optional `Sidekiq` integration (`ServerMiddleware`, `ErrorHandler`, `:quiet`/`:shutdown` flush), `ActiveJob` integration, and `Sentrace::SentryTransport` (`sentry-ruby` in-process transport), update `initializer.rb.tt` and `README.md`, and verify `spec/integration/ruby_integrations_spec.rb` and `spec/integration/sentry_transport_spec.rb` pass

## 5. Multi-Rails Suite & Lint Verification

- [x] 5.1 Run `rtk bundle exec rubocop`, `rtk bundle exec rspec` (Rails `8.1`), and `BUNDLE_GEMFILE=gemfiles/rails_6_1.gemfile rtk bundle exec rspec` (Rails `6.1`) and verify zero offenses and zero failures

## Workflow follow-up

- Sync delta specs and archive `phase-9-native-ruby-sdk-and-integrations`.
- Validate all main specs with `rtk openspec validate --all --strict --no-interactive`.
