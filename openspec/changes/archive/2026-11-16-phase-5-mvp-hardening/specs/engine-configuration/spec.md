# Spec Delta

## ADDED Requirements

### Requirement: Retention batch size and host internal authenticator configuration
`Sentrace::Configuration` SHALL provide a positive integer `retention_batch_size` setting (defaulting to `1000`) and an optional callable `internal_authenticator` setting (defaulting to `nil`) for delegating `/sentrace/internal` authorization to the host Rails application.

#### Scenario: Validating retention_batch_size and internal_authenticator
- **WHEN** a host application configures `retention_batch_size = 500` and a callable `internal_authenticator = ->(request) { ... }`
- **THEN** `Sentrace.configure` accepts both settings and raises `Sentrace::ConfigurationError` if `retention_batch_size <= 0` or `internal_authenticator` does not respond to `#call`
