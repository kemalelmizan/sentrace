# Spec Delta

## ADDED Requirements

### Requirement: Deployment environment attribution label
`Sentrace::Configuration` SHALL provide a `deployment_environment` setting (defaulting to `Rails.env`) that identifies the deployment's logical environment name when answering remote Streamable HTTP MCP requests.

#### Scenario: Custom deployment_environment stamps remote MCP responses
- **GIVEN** a deployment configured with `config.deployment_environment = "staging-eu"`
- **WHEN** that deployment serves MCP queries over `/sentrace/mcp`
- **THEN** returned projects, issues, events, and trends carry `"environment" => "staging-eu"`
