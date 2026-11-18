# project-management Specification

## Purpose
Provides dashboard-free project registration, Sentry-compatible DSN construction and parsing, digest-backed ingestion key lifecycle management, and administrative Rake tasks.

## Requirements

### Requirement: Sentry-compatible DSN formatting and parsing
The system SHALL generate and parse Sentry-compatible DSN strings (`<scheme>://<public_key>@<host>/<project_identifier>`) supporting engine mount prefixes and optional ports, so official `sentry-ruby` clients can target Sentrace without custom transport adapters.

#### Scenario: Generating a DSN for an active project key
- **GIVEN** a project `1` with active public key `a1b2c3d4` and host base URL `https://errors.example.com/sentrace`
- **WHEN** a DSN string is formatted for that project key
- **THEN** the resulting DSN is `https://a1b2c3d4@errors.example.com/sentrace/1`

#### Scenario: Parsing a valid Sentry DSN extracts public key and project identifier
- **WHEN** the DSN `https://a1b2c3d4@errors.example.com/sentrace/1` is parsed
- **THEN** the parser extracts `public_key` `a1b2c3d4`, scheme `https`, host `errors.example.com`, mount path `/sentrace`, and project identifier `1`

#### Scenario: Malformed DSN without public key or project identifier is rejected
- **WHEN** a DSN missing either the userinfo public key or trailing project segment is parsed
- **THEN** the parser raises a structured invalid-DSN error without leaking internal stack details

### Requirement: Project key generation, verification, and rotation
Project provisioning SHALL generate random public keys (or idempotently seed a validated `public_key` via `Project.ensure!` across boots), store secret material solely as constant-time-verified SHA-256 digests, reject revoked or cross-project keys, support key rotation by revoking prior active keys and issuing a fresh key, and MUST invalidate in-process frontend DSN key caches whenever projects or keys are provisioned, rotated, revoked, or destroyed.

#### Scenario: Active public key authenticates its owning project only
- **GIVEN** project `1` with active key `pub_one` and project `2` with active key `pub_two`
- **WHEN** `pub_one` is verified against project `1` versus project `2`
- **THEN** verification succeeds for project `1` and fails for project `2`

#### Scenario: Key rotation revokes previous key and issues a new active key
- **GIVEN** a project `my-app` with active public key `old_key` and a warmed in-process frontend DSN cache
- **WHEN** key rotation is executed for `my-app`
- **THEN** `old_key` is marked `active: false` with `revoked_at` populated, a new active key is persisted, subsequent authentication with `old_key` is rejected, and `Sentrace.frontend_dsn` / `sentrace_meta_tags` immediately reflect the new active key without process restart

#### Scenario: Declarative Project.ensure! idempotently seeds a pinned public key across boots
- **WHEN** `Sentrace::Project.ensure!(slug: "core-monolith", public_key: "pub_prod_0123456789abcdef")` is called on first boot and again on subsequent boots
- **THEN** the project and active `ProjectKey` are created once, subsequent calls return the same `[project, key]` without rotating or duplicating rows, and malformed or cross-project `public_key` values raise `ArgumentError`

### Requirement: Administrative Rake tasks for headless project management
The engine SHALL expose `sentrace:projects`, `sentrace:projects:create[slug]`, `sentrace:projects:rotate_key[slug]`, and `sentrace:bootstrap` (reading optional `SENTRACE_PROJECT_SLUG`, `SENTRACE_PROJECT_PUBLIC_KEY`, `SENTRACE_MCP_TOKEN_NAME`, and `SENTRACE_MCP_TOKEN`) for headless provisioning, printing both `SENTRACE_FRONTEND_DSN` and `SENTRY_DSN` with guidance that explicit DSN env vars are optional overrides for cross-origin frontends or legacy `sentry-ruby`.

#### Scenario: Creating a project via Rake outputs project details and DSN
- **WHEN** an operator runs `bin/rails "sentrace:projects:create[my-app]"`
- **THEN** a project with slug `my-app` and an active key are created and the CLI prints the project slug, ID, public key, and DSN template

#### Scenario: Listing projects displays status and active key metadata without secrets
- **GIVEN** two registered projects in the database
- **WHEN** an operator runs `bin/rails sentrace:projects`
- **THEN** the output lists each project's ID, slug, name, and active public key without exposing secret digests

#### Scenario: Rotating an unknown project slug fails cleanly
- **WHEN** an operator runs `bin/rails "sentrace:projects:rotate_key[missing-app]"`
- **THEN** the task exits non-zero with a clear not-found message and leaves existing project keys unchanged

#### Scenario: Running sentrace:bootstrap idempotently provisions credentials from CI/CD environment variables
- **GIVEN** `SENTRACE_PROJECT_SLUG="erp-web"`, `SENTRACE_PROJECT_PUBLIC_KEY="erp_pub_1234567890abcdef"`, `SENTRACE_MCP_TOKEN_NAME="prod-mcp"`, and `SENTRACE_MCP_TOKEN="snt_mcp_0123456789abcdef0123456789abcdef"`
- **WHEN** `bin/rails sentrace:bootstrap` runs twice in non-interactive CI/CD
- **THEN** both runs exit `0`, persist exactly one active `ProjectKey` and one SHA-256 `McpToken` digest without duplicating or rotating credentials, print `SENTRACE_FRONTEND_DSN` and `SENTRY_DSN` with cross-origin/legacy-SDK guidance, and never echo the raw `SENTRACE_MCP_TOKEN` to stdout
