# Spec Delta

## ADDED Requirements

### Requirement: Native Ruby capture client and async dispatch configuration
`Sentrace::Configuration` SHALL provide `project_slug` (`nil`), `project_id` (`nil`), `capture_unhandled_exceptions` (`true` when a target project is configured, `false` otherwise unless set explicitly), `sample_rate` (`1.0`, `0.0..1.0`), `excluded_exceptions`, `before_send` (`nil` or `#call`), `breadcrumbs_logger` (`[]`), `async_queue_size` (`256`), and `capture_dispatch` (`:async` or `:inline`), rejecting invalid values with `Sentrace::ConfigurationError`.

#### Scenario: Default capture_unhandled_exceptions derives from project_slug or project_id unless overridden
- **WHEN** `Sentrace::Configuration.new` is inspected without a target project, then configured with `project_slug = "monolith"`, and finally configured with `capture_unhandled_exceptions = false`
- **THEN** `capture_unhandled_exceptions` evaluates to `false` initially, `true` once `project_slug` is set, and `false` when explicitly disabled

#### Scenario: Validating sample_rate, before_send, breadcrumbs_logger, async_queue_size, and capture_dispatch
- **WHEN** a host application configures an out-of-range `sample_rate` (`1.5`), a non-callable `before_send`, an unsupported `breadcrumbs_logger` symbol, a non-positive `async_queue_size`, or an unknown `capture_dispatch` mode
- **THEN** `Sentrace.configure` raises `Sentrace::ConfigurationError` for each invalid setting
