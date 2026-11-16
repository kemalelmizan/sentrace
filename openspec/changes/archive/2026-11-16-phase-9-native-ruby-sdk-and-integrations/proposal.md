# Proposal

## Why

Host Rails monoliths running `Sentrace::Engine` on small Puma thread pools (alongside separate Sidekiq worker processes sharing PostgreSQL) currently have to install `sentry-ruby`/`sentry-rails` and hairpin backend Ruby exceptions over external HTTPS, CDNs, and WAFs back into their own Puma threads. Worse, naive in-process error persistence inside an application `ActiveRecord::Base.transaction` fails with `PG::InFailedSqlTransaction` or rolls back with the outer transaction, while background threads spawned before Puma `preload_app!` forks die silently in worker children. Providing a native in-process `Sentrace` Ruby capture SDK, automatic Rack/Rails/Sidekiq/ActiveJob integrations, and a drop-in `Sentrace::SentryTransport` backed by a fork-safe, transaction-isolated `SizedQueue` worker eliminates HTTP hairpinning and allows host applications to drop `sentry-ruby`, `sentry-rails`, and `stackprof` completely if desired.

## What Changes

- **Native `Sentrace` Ruby Client & Fiber/Thread-Isolated Scope API** (aligned with `SPEC.md` Sections 5, 6, and 7):
  - Add `Sentrace::Scope` and top-level scope/context helpers: `Sentrace.with_scope`, `Sentrace.configure_scope`, `Sentrace.current_scope`, `Sentrace.clear_scope!`, `Sentrace.set_tag`, `Sentrace.set_tags`, `Sentrace.set_user`, `Sentrace.set_context`, `Sentrace.set_extra`, and `Sentrace.set_extras`.
  - Add `Sentrace::Breadcrumb` (`category:`, `message:`, `level:`, `type:`, `data:`, `timestamp:`) and `Sentrace.add_breadcrumb(crumb_or_hash = nil, **kwargs)` for ergonomic migration from `Sentry::Breadcrumb.new`.
  - Add `Sentrace.capture_exception(exception, **options)` (`level:`, `tags:`, `contexts:`, `extra:`, `user:`, `fingerprint:`, `handled:`) and `Sentrace.capture_message(message, level: :info, **options)` returning the 32-character hex `event_id` or `nil` when disabled, unsampled, unconfigured, or dropped by `before_send` or queue overflow.
  - Preserve bounded `exception.mechanism` (`type` and `handled`) during `EventNormalizer.normalize` when provided so handled vs unhandled capture metadata survives normalization.
- **Client Configuration & Safe Breadcrumb Loggers (`Sentrace::Configuration`)**:
  - Add `project_slug` and `project_id` (lazily resolved and cached against `Sentrace::Project`), `capture_unhandled_exceptions` (defaulting to `true` when `project_slug` or `project_id` is configured, `false` otherwise unless explicitly set), `sample_rate` (`1.0`), `excluded_exceptions` (default Rails 404/param-missing noise applied only to unhandled integration capture), `before_send` callable (`->(raw_event_hash, hint) { ... }`), `breadcrumbs_logger` (supporting `:active_support_logger` and `:http_logger` without recording raw SQL bind values or HTTP bodies), `async_queue_size` (`256`), and `capture_dispatch` (`:async` or `:inline`).
- **Automatic Rack/Rails, Sidekiq, and ActiveJob Integrations**:
  - Add `Sentrace::Integrations::RackMiddleware` isolating scope per request, attaching sanitized `url`, `method`, and `X-Request-Id` (`action_dispatch.request_id`), and capturing unhandled non-excluded exceptions before re-raising across Rails `6.1`, `7.x`, and `8.x`.
  - Add optional `Sentrace::Integrations::Sidekiq` auto-wired only when `defined?(::Sidekiq)` is truthy (zero hard gem dependency), registering server middleware for per-job scope isolation and `sidekiq` context (`queue`, `jid`, `class`, `retry_count`), an `error_handlers` hook for unhandled job exceptions, and `on(:quiet)` / `on(:shutdown)` hooks invoking `Sentrace.flush(timeout: 2.0)`.
  - Add `Sentrace::Integrations::ActiveJob` via `ActiveSupport.on_load(:active_job)` for per-job scope isolation and unhandled exception capture, deduplicated via `ObjectSpace::WeakMap` so ActiveJob jobs running on Sidekiq are never double-captured.
- **Drop-In `sentry-ruby` In-Process Transport (`Sentrace::SentryTransport`)**:
  - Provide `Sentrace::SentryTransport` (subclassing `::Sentry::Transport` when `sentry-ruby` is loaded) usable via `Sentry.init { |c| c.transport.transport_class = Sentrace::SentryTransport }`, routing `event` error items directly to Sentrace's in-process dispatcher while discarding `transaction`, `profile`, `session`, `sessions`, `attachment`, `log`, and `client_report` items with zero HTTP requests and zero database writes.
- **Transaction Isolation & Puma `preload_app!` Fork Safety**:
  - Dispatch in-process persistence through `Sentrace::AsyncWorker` using a bounded non-blocking `SizedQueue` (`config.async_queue_size = 256`, dropping with a warning on overflow rather than blocking Puma/Sidekiq threads) drained by a background worker thread that checks out its own pooled connection via `ActiveRecord::Base.connection_pool.with_connection`.
  - Track `Process.pid` in `AsyncWorker` so forked Puma (`preload_app!`) or Unicorn worker processes automatically spawn a fresh queue and worker thread on first post-fork capture.
  - Provide `Sentrace.flush(timeout: 2.0)` wired into `at_exit` and Sidekiq lifecycle hooks, and isolate `:inline` dispatch onto a separate pooled connection whenever the caller holds an open or `PG::InFailedSqlTransaction` `ActiveRecord` transaction.
- **Explicit Out-of-Scope Boundaries (`SPEC.md` Section 2 & Section 13)**:
  - Strictly NO tables, columns, or persistence for transactions, spans, APM performance metrics, sessions, replays, logs, or attachments; NO Redis or hard Sidekiq/ActiveJob backend requirement; NO raw SQL bind parameter or HTTP body capture; NO web UI/dashboard; and NO GIN indexes on `sentrace_events.event_data`.

## Capabilities

### New Capabilities
- `ruby-capture-sdk`: Native `Sentrace` Ruby client and thread/fiber-isolated scope API, safe `breadcrumbs_logger` subscribers, automatic Rack/Rails, Sidekiq, and ActiveJob integrations with exception deduplication, drop-in `Sentrace::SentryTransport`, and fork-safe, transaction-isolated `SizedQueue` persistence (`specs/ruby-capture-sdk/spec.md`).

### Modified Capabilities
- `engine-configuration`: Add and validate native Ruby capture and async dispatch settings (`project_slug`, `project_id`, `capture_unhandled_exceptions`, `sample_rate`, `excluded_exceptions`, `before_send`, `breadcrumbs_logger`, `async_queue_size`, `capture_dispatch`) and document backend capture in the generated initializer (`specs/engine-configuration/spec.md`).
- `sentry-ingestion`: Preserve bounded `exception.mechanism` (`type` and `handled`) during event normalization and support zero-HTTP in-process `Sentrace::SentryTransport` error routing alongside HTTP envelope ingestion (`specs/sentry-ingestion/spec.md`).

## Impact

- **Core Ruby library**: `lib/sentrace.rb`, `lib/sentrace/configuration.rb`, `lib/sentrace/breadcrumb.rb`, `lib/sentrace/scope.rb`, `lib/sentrace/event_builder.rb`, `lib/sentrace/async_worker.rb`, `lib/sentrace/capture_dispatcher.rb`, `lib/sentrace/sentry_transport.rb`, `lib/sentrace/breadcrumbs/{active_support_logger,http_logger}.rb`, `lib/sentrace/integrations/{exception_deduplicator,rack_middleware,sidekiq,active_job}.rb`, `lib/sentrace/engine.rb`, and `lib/sentrace/ingestion/event_normalizer.rb`.
- **Generators & docs**: `lib/generators/sentrace/install/templates/initializer.rb.tt` and `README.md`.
- **Test suite**: New unit and integration specs covering scope isolation, capture API, `before_send`/`sample_rate`/`excluded_exceptions`, breadcrumb loggers, Rack/Rails + Sidekiq + ActiveJob deduplication, `Sentrace::SentryTransport`, rolled-back and `PG::InFailedSqlTransaction` ActiveRecord transaction isolation, `Process.fork` worker respawn, and bounded queue overflow across Rails `6.1` and Rails `8.1`.
- **Database & dependencies**: Zero schema changes, zero migrations, and zero new runtime gem dependencies.
