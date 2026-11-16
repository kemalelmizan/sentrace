# Spec Delta

## Purpose

Provides dashboard-free project registration, Sentry-compatible DSN construction and parsing, digest-backed ingestion key lifecycle management, and administrative Rake tasks.

## ADDED Requirements

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
Project provisioning SHALL generate cryptographically random public keys, store any secret material solely as SHA-256 digests verified in constant time, reject revoked or inactive keys, and support rotating a project's key by revoking prior active keys and issuing a fresh active key.

#### Scenario: Active public key authenticates its owning project only
- **GIVEN** project `1` with active key `pub_one` and project `2` with active key `pub_two`
- **WHEN** `pub_one` is verified against project `1` versus project `2`
- **THEN** verification succeeds for project `1` and fails for project `2`

#### Scenario: Key rotation revokes previous key and issues a new active key
- **GIVEN** a project `my-app` with active public key `old_key`
- **WHEN** key rotation is executed for `my-app`
- **THEN** `old_key` is marked `active: false` with `revoked_at` populated, a new active key is persisted, and subsequent authentication with `old_key` is rejected

### Requirement: Administrative Rake tasks for headless project management
The engine SHALL expose `bin/rails sentrace:projects`, `bin/rails sentrace:projects:create[slug]`, and `bin/rails sentrace:projects:rotate_key[slug]` so operators can list projects, provision new projects with initial DSNs, and rotate keys from the CLI without a web UI.

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
