# sentry-ingestion Specification

## ADDED Requirements

### Requirement: Non-cacheable ingestion HTTP responses across Rack 2.2 and 3.x
Every response from `IngestionController` (`POST` and `OPTIONS /api/:project_id/envelope`, across `200`, `202`, `204`, `400`, `401`, `413`, and `500` statuses) SHALL include `Cache-Control: no-store` and SHALL use Rack `2.2`-compatible numeric status codes where Rack 3 renamed status symbols.

#### Scenario: Ingestion success, preflight, and error responses carry Cache-Control no-store
- **GIVEN** an active project key and `cors_allowed_origins = ["https://spa.example.com"]`
- **WHEN** clients send `OPTIONS /api/1/envelope`, a valid `POST /api/1/envelope`, an unauthorized `POST`, and an oversized `POST`
- **THEN** every response includes `Cache-Control: no-store` and oversized payloads return numeric HTTP `413` on both Rack `2.2` and Rack `3.x`

## MODIFIED Requirements

### Requirement: Pre-parse body size and gzip decompression limits
The ingestion endpoint (`POST /api/:project_id/envelope`) SHALL enforce `max_envelope_size` on both raw request bodies and `gzip`-compressed streams before JSON parsing, rejecting oversized payloads with numeric HTTP `413` (`Cache-Control: no-store`) on Rack `>= 2.2` without persisting records or leaking internal stack traces.

#### Scenario: Oversized raw envelope is rejected before parsing
- **GIVEN** `max_envelope_size` configured to `1024` bytes
- **WHEN** a client posts a `2048`-byte envelope to `POST /api/:project_id/envelope`
- **THEN** the endpoint responds with HTTP `413` and `Cache-Control: no-store`, and creates zero database rows

#### Scenario: Compressed gzip envelope within size limit is accepted
- **GIVEN** a valid `gzip`-compressed Sentry envelope whose decompressed size is below `max_envelope_size`
- **WHEN** a client posts it with `Content-Encoding: gzip`
- **THEN** the endpoint inflates and processes the envelope and responds with HTTP `200` and `Cache-Control: no-store`

#### Scenario: Oversized gzip stream is aborted during inflation
- **GIVEN** `max_envelope_size` configured to `2048` bytes
- **WHEN** a client posts a `gzip` payload that inflates past `2048` bytes
- **THEN** inflation halts immediately and the endpoint responds with HTTP `413` and `Cache-Control: no-store`
