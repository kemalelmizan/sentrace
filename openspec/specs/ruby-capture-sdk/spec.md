# ruby-capture-sdk Specification

## Purpose
Provides a native in-process Ruby error capture SDK, thread/fiber-isolated scopes, automatic Rack/Rails, Sidekiq, and ActiveJob integrations, a drop-in `sentry-ruby` transport, and a fork-safe, transaction-isolated background persistence worker.

## Requirements

### Requirement: Fiber and thread isolated scope management and context helpers
The Ruby SDK SHALL maintain fiber- and thread-isolated scopes via `Sentrace.current_scope`, `Sentrace.with_scope`, `Sentrace.configure_scope`, and `Sentrace.clear_scope!`, and SHALL expose `set_tag`, `set_tags`, `set_user`, `set_context`, `set_extra`, `set_extras`, and `add_breadcrumb` (`Sentrace::Breadcrumb` or Hash) bounded by `max_breadcrumbs`.

#### Scenario: Nested with_scope mutations and concurrent thread scopes do not leak
- **GIVEN** a configured target project and `Sentrace.set_tag("service", "billing")` on the current thread
- **WHEN** `Sentrace.with_scope` sets `tag("step", "charge")`, `user(id: 42)`, and adds a `Sentrace::Breadcrumb.new(category: "auth", message: "verified")` before calling `Sentrace.capture_exception`, while a second thread sets `tag("service", "Fulfillment")`
- **THEN** the first captured event records `service == "billing"`, `step == "charge"`, hashed user `42`, and the `"auth"` breadcrumb, subsequent captures outside `with_scope` omit `"step"`, and the two threads never share scope mutations

#### Scenario: Breadcrumb ring buffer respects max_breadcrumbs
- **GIVEN** `max_breadcrumbs = 3`
- **WHEN** five breadcrumbs (`crumb-1` through `crumb-5`) are added via `Sentrace.add_breadcrumb`
- **THEN** the captured event retains only `crumb-3`, `crumb-4`, and `crumb-5` in chronological order

### Requirement: Top-level exception and message capture API with sampling and before_send
`Sentrace.capture_exception(exception, **options)` and `Sentrace.capture_message(message, level: :info, **options)` SHALL return the 32-character hex `event_id` when accepted, or `nil` when disabled, unconfigured, excluded by `sample_rate`, dropped by `before_send(raw_event_hash, hint)`, or rejected by queue overflow.

#### Scenario: Capturing chained Ruby exceptions and explicit capture of excluded_exceptions
- **GIVEN** `project_slug` pointing to a provisioned project and `ActionController::RoutingError` listed in `excluded_exceptions`
- **WHEN** application code explicitly calls `Sentrace.capture_exception(error, level: :warning, tags: { area: "checkout" }, extra: { retries: 2 }, fingerprint: ["custom-group"], handled: true)` on an exception with a nested `cause`, and also explicitly captures an `ActionController::RoutingError`
- **THEN** both calls return 32-character hex `event_id` values and persist normalized events with Ruby stack frames (`in_app` marked accurately), `mechanism: { "type" => "generic", "handled" => true }`, custom fingerprint, tags, and `contexts["extra"]`

#### Scenario: Dropping or mutating events via sample_rate and before_send
- **GIVEN** `before_send = ->(event, _hint) { event["message"] == "drop-me" ? nil : event.tap { |e| e["tags"] = (e["tags"] || {}).merge("hook" => "applied") } }`
- **WHEN** `Sentrace.capture_message("drop-me")` and `Sentrace.capture_message("keep-me", level: :warning)` are called, and another capture runs with `sample_rate = 0.0`
- **THEN** `"drop-me"` and the `sample_rate = 0.0` call return `nil` and write zero rows, while `"keep-me"` returns a 32-character `event_id` and persists with `level == "warning"` and `tags["hook"] == "applied"`

### Requirement: Safe ActiveSupport and Net::HTTP breadcrumb loggers
When `breadcrumbs_logger` includes `:active_support_logger` or `:http_logger`, the SDK SHALL record controller action, SQL query name/duration, and outbound `Net::HTTP` method/URL/status breadcrumbs while MUST NOT record raw SQL bind values, HTTP request/response bodies, or Sentrace's own internal queries and endpoints.

#### Scenario: Recording SQL and HTTP metadata breadcrumbs without raw bind parameters or bodies
- **GIVEN** `breadcrumbs_logger = %i[active_support_logger http_logger]`
- **WHEN** ActiveSupport emits a `sql.active_record` notification carrying sensitive bind values and an outbound `Net::HTTP` request posts a JSON body to `https://api.partner.test/v1/charge?token=sec_1&mode=live`
- **THEN** the scope records SQL and HTTP breadcrumbs with sanitized URL (`token=[REDACTED]&mode=live`), HTTP method, and status code while omitting SQL bind values, raw SQL literals, HTTP bodies, and `sentrace_*` table queries

### Requirement: Automatic Rack, Sidekiq, and ActiveJob capture with deduplication
The SDK SHALL capture unhandled non-excluded exceptions in Rack/Rails requests (sanitized `url`, `method`, `X-Request-Id`, and fallback `"#{method} #{path}"` culprit without query string), Sidekiq jobs when `::Sidekiq` is defined, and ActiveJob runs, MUST exclude `ActionController::Live::ClientDisconnected` and non-`in_app` Puma stream-closed `IOError`s while capturing `in_app` `IOError`s, MUST re-raise, and MUST NOT double-capture ActiveJob on Sidekiq.

#### Scenario: Rack middleware isolates per-request scope, skips excluded 404 errors, and captures unhandled 500 errors
- **GIVEN** a Rails application with `project_slug` configured and `excluded_exceptions` containing `ActiveRecord::RecordNotFound`
- **WHEN** request A raises `ActiveRecord::RecordNotFound` and request B (`X-Request-Id: req-500-xyz`, `POST /orders?token=secret`) raises `RuntimeError("boom")`
- **THEN** request A creates zero events, request B persists one unhandled event (`mechanism.handled == false`, `tags["request_id"] == "req-500-xyz"`, sanitized `request.url`) and re-raises `RuntimeError`, and scope state from request B does not leak to request C

#### Scenario: Middleware exception before routing populates fallback HTTP method and path culprit and ignores Puma client disconnects
- **GIVEN** `Sentrace::Integrations::RackMiddleware` wrapping an app without `action_dispatch.request.path_parameters`
- **WHEN** request A (`GET /api/v1/reports?token=secret`) raises an `in_app` `IOError("upstream socket closed")` and request B raises a Puma socket-layer `IOError("stream closed in another thread")` with zero `in_app` backtrace frames (or `ActionController::Live::ClientDisconnected`)
- **THEN** request A persists one event with `culprit == "GET /api/v1/reports"` (omitting `?token=secret`), while request B persists zero events and still re-raises the exception

#### Scenario: ActiveJob running atop Sidekiq captures an unhandled job exception exactly once
- **GIVEN** both `Sentrace::Integrations::ActiveJob` and `Sentrace::Integrations::Sidekiq` active in the same worker process
- **WHEN** an ActiveJob job executed through Sidekiq server middleware and error handlers raises an unhandled `StandardError`
- **THEN** the exception is re-raised, Sidekiq/ActiveJob context (`queue`, `jid`, `class`, `retry_count`) is recorded without leaking scope to subsequent jobs, and exactly one `sentrace_events` row is persisted

### Requirement: Drop-in sentry-ruby in-process transport
When `sentry-ruby` is loaded, `Sentrace::SentryTransport` SHALL accept `Sentry.init` transport assignment, route `event` error envelope items directly to Sentrace's in-process dispatcher without HTTP requests, and discard `transaction`, `profile`, `session`, `sessions`, `attachment`, `log`, and `client_report` items with zero database writes.

#### Scenario: Routing sentry-ruby error envelopes in-process while discarding non-error items
- **GIVEN** `Sentry.init` configured with `config.transport.transport_class = Sentrace::SentryTransport` targeting a Sentrace project
- **WHEN** `Sentry.capture_exception` sends an error event and the transport also receives `transaction`, `session`, and `client_report` envelope items
- **THEN** zero outbound HTTP connections are opened, the error event is persisted in `sentrace_events`, and the `transaction`, `session`, and `client_report` items create zero database rows

### Requirement: Bounded async worker, ActiveRecord transaction isolation, and fork safety
In-process capture MUST NOT execute persistence on a caller connection with an open or aborted `ActiveRecord` transaction; `:async` dispatch SHALL enqueue onto a non-blocking `SizedQueue` (`async_queue_size`, dropping with a warning on overflow) drained via `connection_pool.with_connection`, respawn workers when `Process.pid` changes after `fork`, and drain via `Sentrace.flush(timeout:)`.

#### Scenario: Capturing inside an aborted PG::InFailedSqlTransaction and rolled-back ActiveRecord transaction
- **GIVEN** an application `ActiveRecord::Base.transaction` block where a failing SQL query puts the caller connection into `PG::InFailedSqlTransaction` before rolling back
- **WHEN** the rescue block calls `Sentrace.capture_exception(error)` and re-raises to roll back the outer transaction (under both `:async` with `Sentrace.flush` and `:inline` dispatch)
- **THEN** the captured `sentrace_events` and `sentrace_issues` rows remain durably committed in PostgreSQL after the caller's transaction rolls back

#### Scenario: Non-blocking overflow protection and post-fork worker respawn
- **GIVEN** a live parent `AsyncWorker` before `Process.fork` (simulating Puma `preload_app!`) and a bounded `async_queue_size`
- **WHEN** a forked child process calls `Sentrace.capture_exception` followed by `Sentrace.flush(timeout: 2.0)`, or when an error burst exceeds `async_queue_size` while the worker is paused
- **THEN** the forked child automatically spawns its own worker thread and persists its event, and queue overflow returns `nil` immediately with a warning log without blocking the caller thread

### Requirement: Isolated configuration and test helper harness for host RSpec suites
Sentrace SHALL expose `Sentrace.with_configuration(**overrides) { |config| ... }` and `Sentrace::TestHelpers` (`with_sentrace_test_config(**overrides)`) that snapshot and restore `Sentrace.configuration`, clear `CaptureDispatcher` and `FrontendDsnResolver` caches, reset exception deduplication state, and clear fiber/thread scopes before and after the block (defaulting `enabled: true` and `capture_dispatch: :inline` in `with_sentrace_test_config`).

#### Scenario: Isolating host RSpec example overrides with Sentrace::TestHelpers and Sentrace.with_configuration
- **GIVEN** a host test suite where `Sentrace.configuration.enabled` is `false` and `capture_dispatch` is `:async`
- **WHEN** a spec runs `with_sentrace_test_config(project_slug: "test-app") { Sentrace.set_tag("spec", "1"); Sentrace.capture_message("hello") }`
- **THEN** the message is persisted synchronously inside the block with `tags["spec"] == "1"`, and after the block exits (even on exception) `Sentrace.configuration.enabled` returns to `false`, `capture_dispatch` returns to `:async`, `Sentrace.current_scope.tags` is empty, and in-memory project caches are cleared
