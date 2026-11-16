# Design

## Context

See `proposal.md` for motivation and capability scope. `Sentrace::Ingestion::Processor.ingest_event` already accepts a string-keyed Sentry v7 raw event hash, normalizes and truncates fields (`EventNormalizer`), scrubs sensitive data (`Sanitizer`), computes issue fingerprints (`Issues::Fingerprint`), and upserts `sentrace_issues` + inserts `sentrace_events` via `Issues::Grouper.persist!`. However, all backend Ruby error capture previously depended on an external `sentry-ruby` HTTP client posting over the network to `IngestionController`.

In production enterprise deployments (`Rails >= 6.1`, `Puma` with `preload_app!` and 5 threads, separate `Sidekiq 6.5` workers sharing PostgreSQL `>= 12`), in-process backend capture must satisfy four strict runtime constraints:
1. **Transaction isolation**: Exceptions rescued or raised inside `ActiveRecord::Base.transaction` often run while the caller's PostgreSQL connection is in `PG::InFailedSqlTransaction` (`PQTRANS_INERROR`) or about to `ROLLBACK`. Running `Issues::Grouper.persist!` on the caller's connection either raises `PG::InFailedSqlTransaction` or rolls back the captured error along with the failed business transaction.
2. **Puma `preload_app!` / Unicorn fork safety**: Ruby `Thread` instances do not survive `Process.fork`. Any background worker thread spawned in the master process before `fork` appears dead (`alive? == false`) in child workers while holding stale parent queue state.
3. **Bounded memory & non-blocking backpressure**: Error storms must never block Puma request threads or Sidekiq job threads, nor allocate unbounded in-memory queues.
4. **Optional gem boundaries**: Sidekiq and `sentry-ruby` integrations must activate only when those constants are loaded by the host application, keeping `sentrace.gemspec` free of Redis, Sidekiq, or `sentry-ruby` runtime dependencies.

## Goals / Non-Goals

**Goals:**
- Provide a clean separation between pure domain modules under `lib/sentrace/` (`Breadcrumb`, `Scope`, `EventBuilder`, `AsyncWorker`, `CaptureDispatcher`, `SentryTransport`, `Breadcrumbs::*`, `Integrations::*`) and existing engine models/controllers under `app/{models,controllers}/sentrace/`, requiring zero schema migrations or new tables.
- Guarantee caller-thread synchronous scope snapshot, sampling, and `before_send` execution so `Sentrace.capture_exception` / `capture_message` immediately return a 32-char `event_id` (or `nil`), while persistence executes on an isolated pooled database connection.
- Prevent duplicate event capture when an unhandled exception bubbles through `ActiveJob` -> `Sidekiq::ServerMiddleware` -> `Sidekiq::ErrorHandler` or Rails middleware layers.

**Non-Goals:**
- Persisting transactions, spans, profiles, sessions, logs, or client reports (all non-error `Sentry::Envelope::Item` types are short-circuited in memory).
- Persisting raw SQL bind values or HTTP request/response bodies in breadcrumbs.
- Introducing new PostgreSQL tables, columns, or GIN indexes (`sentrace_issues` and `sentrace_events` schemas and unique indexes `(project_id, fingerprint)` / `(project_id, event_id)` remain unchanged).

## Decisions

### 1. Fiber-Local Scope Stack (`Thread.current` Fiber Storage)
- **Choice**: Store the scope stack in `Thread.current[:sentrace_scope_stack]` (which in Ruby `>= 3.2` is fiber-local per `Fiber`, isolating both threads and fibers!). `Sentrace.current_scope` lazily initializes `[Scope.new]`; `Sentrace.with_scope` pushes `current_scope.deep_clone` and pops in `ensure`; `Sentrace.configure_scope` yields `current_scope`; `Sentrace.clear_scope!` resets the stack to `[Scope.new]`.
- **Alternatives considered**: `Fiber[:sentrace_scope]` inherited storage — rejected because inherited fiber storage shares mutable object references across child fibers unless cloned on spawn, whereas `Thread.current[...]` gives clean per-fiber/per-thread isolation in Puma and Sidekiq.

### 2. Synchronous Event Assembly + Bounded Non-Blocking `AsyncWorker` (`SizedQueue` + `Process.pid`)
- **Choice**:
  1. On the caller thread/fiber, `CaptureDispatcher` checks `config.enabled` and target project configuration (`project_id` / `project_slug` or explicit `:project_id` override), evaluates `config.sample_rate`, builds the string-keyed Sentry v7 raw event hash via `EventBuilder` (merging `Sentrace.current_scope` and per-call options, formatting Ruby `Exception` + chained `exception.cause` up to depth 5 in oldest-to-newest `values` order with `in_app` classification), and invokes `config.before_send&.call(raw_event, hint)`. If dropped or invalid, return `nil` immediately.
  2. In `:async` mode (default), `AsyncWorker.enqueue` acquires a lightweight `Mutex`, checks `@pid == Process.pid && @worker_thread&.alive?` (reinitializing `@pid = Process.pid`, `@queue = SizedQueue.new(config.async_queue_size)`, and spawning a new daemon `Thread` if forked or stopped), and pushes the job non-blockingly via `@queue.push(job, true)`. On `ThreadError` (queue full), it logs a single warning (`Rails.logger&.warn` or `$stderr`) and returns `false` so `CaptureDispatcher` returns `nil` without blocking.
  3. The background worker thread processes each job inside `ActiveRecord::Base.connection_pool.with_connection`, resolving `project_id` (cached by `[project_id, project_slug]` in `CaptureDispatcher`) and calling `Ingestion::Processor.ingest_event`.
  4. `Sentrace.flush(timeout: 2.0)` enqueues a synchronization barrier / waits on a `ConditionVariable` until `@queue.empty? && @in_flight.zero?` up to `timeout` seconds, and is registered in `at_exit` and Sidekiq `:quiet` / `:shutdown` lifecycle hooks.
- ** `:inline` Dispatch Transaction Isolation**:
  - When `config.capture_dispatch == :inline` (used for deterministic test suites), `CaptureDispatcher` inspects whether the caller holds an open application transaction or an aborted PostgreSQL connection (`conn.transaction_open? && (raw_in_error?(conn) || conn.current_transaction.joinable?)`). Note that Rails's `use_transactional_tests` outer fixture wrapper sets `current_transaction.joinable? == false`, whereas every application `ActiveRecord::Base.transaction` block has `joinable? == true` (and any failed SQL statement sets `PG::PQTRANS_INERROR`). Whenever either condition holds, `:inline` executes persistence synchronously on a short-lived `Thread.new { ActiveRecord::Base.connection_pool.with_connection { ... } }.value`, guaranteeing `Issues::Grouper.persist!` never runs on an aborted or rolling-back caller transaction while still working seamlessly with RSpec transactional fixtures when no inner app transaction is open!
- **Alternatives considered**: ActiveJob background enqueue — rejected because ActiveJob configured with `:async` or `:inline` or DB-backed queues (GoodJob/SolidQueue) would fail on the caller's aborted PostgreSQL connection (`PG::InFailedSqlTransaction`) or create infinite recursion when ActiveJob itself errors.

### 3. Cross-Layer Exception Deduplication via `ObjectSpace::WeakMap`
- **Choice**: `Sentrace::Integrations::ExceptionDeduplicator` tracks already-captured `Exception` instances in an `ObjectSpace::WeakMap` guarded by a `Mutex`.
  - **RackMiddleware**: Inserted after `ActionDispatch::DebugExceptions` (falling back to `app.middleware.use` if absent) so `env["action_dispatch.request_id"]` is already populated while unhandled controller exceptions have not yet been swallowed into HTTP 500 responses. Wraps `app.call(env)` in an isolated scope, attaches sanitized `request` (`url`, `method`, `headers: { "X-Request-Id" => ... }`), captures unhandled exceptions not matching `config.excluded_exceptions` (`handled: false`, `mechanism: "rack"`), marks them in `ExceptionDeduplicator`, and re-raises; also checks `env["action_dispatch.exception"]` if downstream middleware caught and stored an exception.
  - **ActiveJob & Sidekiq**: `ActiveJob` uses `around_perform` to isolate scope, record `active_job` context, capture unhandled non-excluded exceptions (`mechanism: "active_job"`), mark via `ExceptionDeduplicator`, and re-raise. `Sidekiq::ServerMiddleware` isolates scope per job and attaches `sidekiq` context (`queue`, `jid`, `class`, `retry_count`), while `Sidekiq::ErrorHandler` captures unhandled exceptions (`mechanism: "sidekiq"`) unless already marked in `ExceptionDeduplicator`.
- **Alternatives considered**: Setting an instance variable `@_sentrace_captured = true` on the exception — rejected because frozen `Exception` objects raise `FrozenError` on `instance_variable_set`. `ObjectSpace::WeakMap` handles frozen exceptions safely without retaining garbage-collected exceptions.

### 4. `Sentrace::SentryTransport` Compatibility (`sentry-ruby ~> 5.28`)
- **Choice**: Autoload `Sentrace::SentryTransport` (`lib/sentrace/sentry_transport.rb`). When `defined?(::Sentry::Transport)`, subclass `::Sentry::Transport` and implement `send_envelope(envelope)` (and `send_data` no-op safety): iterate `envelope.items`, check `item.type` (`"event"` is routed; `"transaction"`, `"profile"`, `"session"`, `"sessions"`, `"attachment"`, `"log"`, `"client_report"`, `"check_in"`, `"span"` are discarded immediately), deep-stringify `item.payload` (or JSON-parse if String), resolve target `project_id` from `@dsn` (if its numeric project ID exists) or `Sentrace.configuration`, and pass to `CaptureDispatcher.dispatch_raw_event`.

## Risks / Trade-offs

- **[Risk] Process crash (`SIGKILL`) loses events still sitting in the in-memory `SizedQueue`** → Mitigation: Bounded to at most `async_queue_size` (`256`) events; graceful shutdowns (`SIGTERM` in Puma/Sidekiq) trigger `at_exit` and Sidekiq `:quiet`/`:shutdown` `Sentrace.flush(timeout: 2.0)`.
- **[Risk] `project_slug` configured before `sentrace:bootstrap` creates the project row** → Mitigation: `CaptureDispatcher` resolves `project_id` lazily on capture via `Sentrace::Project.where(slug: slug).pick(:id)`, caches only non-nil IDs (invalidated on `reset_configuration!` or config change), and logs a non-fatal warning returning `nil` if the project does not exist yet so host app boot never crashes.
- **[Risk] Recursive error or breadcrumb loops during Sentrace persistence** → Mitigation: `Breadcrumbs::ActiveSupportLogger` ignores `sql.active_record` events with `name == "SCHEMA"` or SQL touching `sentrace_` tables (and ignores internal `Sentrace::` controllers), `Breadcrumbs::HttpLogger` ignores URLs matching configured Sentrace MCP/DSN endpoints, and `AsyncWorker` rescues internal persistence exceptions with a Thread-local re-entrancy guard.

## Migration Plan

1. Existing Sentrace installations require zero database migrations and continue accepting HTTP envelopes unchanged.
2. Host Rails monoliths can either:
   - Configure `config.project_slug = ENV.fetch("SENTRACE_PROJECT_SLUG", "monolith")` in `config/initializers/sentrace.rb` and remove `sentry-ruby` / `sentry-rails` completely, OR
   - Keep `Sentry.*` call sites during incremental migration by setting `Sentry.init { |c| c.transport.transport_class = Sentrace::SentryTransport }`.
3. Rollback is a pure gem/initializer revert because database tables and `event_data` schema are backwards-compatible.
