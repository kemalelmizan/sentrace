## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Isolated configuration and test helper harness for host RSpec suites
Sentrace SHALL expose `Sentrace.with_configuration(**overrides) { |config| ... }` and `Sentrace::TestHelpers` (`with_sentrace_test_config(**overrides)`) that snapshot and restore `Sentrace.configuration`, clear `CaptureDispatcher` and `FrontendDsnResolver` caches, reset exception deduplication state, and clear fiber/thread scopes before and after the block (defaulting `enabled: true` and `capture_dispatch: :inline` in `with_sentrace_test_config`).

#### Scenario: Isolating host RSpec example overrides with Sentrace::TestHelpers and Sentrace.with_configuration
- **GIVEN** a host test suite where `Sentrace.configuration.enabled` is `false` and `capture_dispatch` is `:async`
- **WHEN** a spec runs `with_sentrace_test_config(project_slug: "test-app") { Sentrace.set_tag("spec", "1"); Sentrace.capture_message("hello") }`
- **THEN** the message is persisted synchronously inside the block with `tags["spec"] == "1"`, and after the block exits (even on exception) `Sentrace.configuration.enabled` returns to `false`, `capture_dispatch` returns to `:async`, `Sentrace.current_scope.tags` is empty, and in-memory project caches are cleared
