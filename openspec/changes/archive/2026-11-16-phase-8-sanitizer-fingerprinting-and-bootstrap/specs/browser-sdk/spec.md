# browser-sdk Specification (Delta)

## MODIFIED Requirements

### Requirement: Sentry v7 envelope serialization, transport fallback, and client privacy scrubbing
The SDK SHALL serialize events as newline-delimited Sentry v7 envelopes sent to `/api/:project_id/envelope?sentry_key=<public_key>&sentry_version=7&sentry_client=sentrace-js/<version>` via `fetch` (`keepalive: true`, `text/plain;charset=UTF-8`) with `navigator.sendBeacon` fallback, redacting credential and auth-session query parameters unless exempted by `allowFields` while preserving non-auth `*_session_id` keys.

#### Scenario: Delivering valid Sentry v7 envelope and redacting sensitive URL query parameters
- **GIVEN** `sentrace` initialized with DSN `https://pub123@errors.example.com/sentrace/7` on page `https://shop.example.com/reset?token=secret123&step=2`
- **WHEN** `captureMessage("Reset failed")` is called
- **THEN** the SDK posts a 3-line Sentry v7 envelope to `https://errors.example.com/sentrace/api/7/envelope?sentry_key=pub123&sentry_version=7&sentry_client=sentrace-js/0.1.0` with `token=[REDACTED]` and `step=2` in `request.url`

#### Scenario: Preserving domain session foreign keys and honoring allowFields in client URL scrubbing
- **GIVEN** `sentrace` initialized with `allowFields: ["token_present"]` on URL `https://app.example.com/reviews?calibration_session_id=77&session_id=sec_1&token_present=1&access_token=sec_2`
- **WHEN** URL scrubbing runs for `request.url` and navigation/fetch breadcrumbs
- **THEN** `calibration_session_id=77` and `token_present=1` remain intact while `session_id=[REDACTED]` and `access_token=[REDACTED]` are masked
