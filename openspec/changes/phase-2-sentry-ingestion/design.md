# Design

## Context

Phase 1 delivered `Sentrace::Configuration`, `Sentrace::Dsn`, the four PostgreSQL tables (`sentrace_projects`, `sentrace_project_keys`, `sentrace_issues`, `sentrace_events`), and headless project provisioning. Phase 2 connects incoming Sentry SDK HTTP traffic (`sentry-ruby` `5.28.1`) to PostgreSQL while upholding strict size, privacy, and concurrency invariants. See `proposal.md` for motivation and scope.

## Goals / Non-Goals

**Goals:**
- Stream-bound and authenticate `POST /api/:project_id/envelope(/)` requests before parsing untrusted payloads.
- Keep `EnvelopeParser`, `EventNormalizer`, `Sanitizer`, and `Fingerprint` pure, stateless Ruby modules in `lib/sentrace/` testable in milliseconds without database I/O.
- Guarantee atomic `(project_id, fingerprint)` issue creation/increment and `(project_id, event_id)` deduplication in a single PostgreSQL transaction without race-condition failures.
- Prove wire-level compatibility with an unmocked `sentry-ruby` (`5.28.1`) client via Rack/Net::HTTP transport adapter in specs.

**Non-Goals:**
- Asynchronous background job queueing by default (synchronous PostgreSQL persistence easily meets the `< 100 ms` target in `SPEC.md` §11 without requiring Redis/Sidekiq; optional ActiveJob hooks remain non-mandatory).
- Storing raw envelopes, attachments, transactions, spans, or sessions.

## Decisions

### 1. Ordered security pipeline in `Sentrace::IngestionController`
- **Decision**: Execute checks in strict order:
  1. Verify `Sentrace.configuration.enabled` (return `202 Accepted` `{ "id": nil }` if disabled).
  2. Check `Content-Length` and raw stream length against `max_envelope_size` (`413` if exceeded).
  3. Authenticate `project_id` + `public_key` (extracted from `X-Sentry-Auth`, `Authorization: Sentry ...`, `?sentry_key=`, or bounded first-line envelope header `dsn`) via `ProjectKey.authenticate_public_key` BEFORE decompressing full gzip streams or parsing items (`401` if invalid/revoked). Note: if `Content-Encoding: gzip` is used and `X-Sentry-Auth` is absent, inflate at most the first `4 KB` header chunk to check envelope `dsn`, still bounded by `max_envelope_size`.
  4. Stream-inflate `gzip` (when `Content-Encoding: gzip`) in `16 KB` chunks aborting immediately with `413` if total inflated bytes exceed `max_envelope_size`.
  5. Parse envelope items and persist `event` items via `Sentrace::Ingestion::Processor`, rescuing `EnvelopeParser::ParseError` -> `400 Bad Request` and unexpected `StandardError` -> generic `500` JSON without leaking DB/Ruby internals, while filtering envelope bodies from Rails parameter/request logs.
- **Rationale**: Directly enforces `SPEC.md` §9.1, §10, and §13 ("Enforce request body limits before JSON parsing", "Validate project credentials before expensive processing", "Avoid logging raw envelope payloads").
- **Alternatives considered**: Rack middleware for envelope parsing — rejected because keeping ingestion scoped to `Sentrace::IngestionController` avoids overhead on every host-app request.

### 2. Binary-safe Sentry Envelope parser (`lib/sentrace/ingestion/envelope_parser.rb`)
- **Decision**: Scan envelope bytes using `StringScanner` / byte offsets rather than `String#lines`:
  - Read line 1 as JSON `envelope_header`.
  - Loop while bytes remain: read `item_header` JSON line; if `item_header["length"]` is an integer, slice exact `length` bytes (plus optional trailing `\n`); otherwise slice up to next `\n` (or EOF).
  - Only JSON-parse item payloads when `(item_header["type"] || "event") == "event"`; skip/discard `transaction`, `session`, `sessions`, `attachment`, `client_report`, `profile`, `replay_event`, `replay_recording`, and unknown types immediately without allocating parsed hashes!
- **Rationale**: Binary `attachment` items can contain raw `\n` bytes; honoring `item_header["length"]` prevents framing corruption while skipping JSON parsing on discarded `transaction`/`profile` payloads saves CPU and allocations.
- **Alternatives considered**: `body.split("\n").each_slice(2)` — rejected because binary attachments with embedded newlines or trailing newlines break naive line splitting.

### 3. Normalization, truncation, and sanitization order (`EventNormalizer` -> `Sanitizer` -> bounds check)
- **Decision**:
  1. `EventNormalizer` extracts canonical fields (`event_id`, `occurred_at`, `level`, `platform`, `logger`, `environment`, `release`, `culprit`, `fingerprint`, and `event_data` with `exception` from outermost `exception.values.last`, `message`, `request`, `breadcrumbs` tail-kept most recent `max_breadcrumbs`, `tags`, `contexts` allow-listed/bounded to `max_context_entries`, and `user`). Stack frames keep the `max_stack_frames` most relevant frames (tail/innermost frames where the crash occurred, matching Ruby/Sentry backtrace order where `frames.last` is crash site!).
  2. `Sanitizer` strips forbidden `request` keys (retaining only query-scrubbed `url` and `method`), removes `os`/`env` raw environment dumps, hashes `user["id"]` (or fallback user key) with `OpenSSL::HMAC.hexdigest("SHA256", "#{secret}:sentrace:project:#{project_id}", raw_id)` while dropping `email`/`username`/`ip_address`, recursively redacts keys matching `config.redact_fields` plus Luhn/PAN-like card patterns, runs optional `config.sanitizer.call(event_data)`, and enforces UTF-8 byte-safe truncation (`String#byteslice` + `scrub`) and `max_context_bytes` (`8 KB` serialized JSON).
- **Rationale**: Running bounds enforcement both during extraction and after custom `config.sanitizer` guarantees host custom sanitizers cannot accidentally blow past PostgreSQL JSONB size budgets.
- **Alternatives considered**: Storing `exception.values.first` — rejected after verifying `sentry-ruby` `ExceptionInterface.build` reverses the cause chain so `values.last` is the primary raised exception.

### 4. Atomic PostgreSQL deduplication + issue upsert (`Sentrace::Issues::Grouper` & `Processor`)
- **Decision**: Inside a single database transaction per accepted event:
  1. Attempt insert into `sentrace_events` (or check/insert with `ON CONFLICT (project_id, event_id) DO NOTHING`):
     - Specifically, first upsert the issue via raw parameterized PostgreSQL `INSERT INTO sentrace_issues (...) VALUES (...) ON CONFLICT (project_id, fingerprint) DO UPDATE SET last_seen_at = GREATEST(sentrace_issues.last_seen_at, EXCLUDED.last_seen_at), first_seen_at = LEAST(sentrace_issues.first_seen_at, EXCLUDED.first_seen_at), updated_at = EXCLUDED.updated_at RETURNING id`?
     - **Wait — subtle edge case!** If we increment `event_count` in the issue upsert BEFORE checking whether `(project_id, event_id)` is a duplicate, a duplicate event would either require rolling back or skipping increment!
     - **Cleanest zero-race solution**:
       1) Check `Event.exists?(project_id: project.id, event_id: normalized_event_id)` fast-path via unique index `index_sentrace_events_on_project_event_id` -> return early if already ingested!
       2) Open transaction:
          - Upsert `sentrace_issues` on `(project_id, fingerprint)` returning `issue_id` (without incrementing `event_count` yet, initializing `event_count: 0` on insert).
          - Insert into `sentrace_events` with `ON CONFLICT (project_id, event_id) DO NOTHING RETURNING id`.
          - **ONLY IF** `sentrace_events` returned an inserted `id` (proving this transaction won the `(project_id, event_id)` race!): execute atomic `UPDATE sentrace_issues SET event_count = event_count + 1, last_seen_at = GREATEST(last_seen_at, $occurred_at), first_seen_at = LEAST(first_seen_at, $occurred_at), level = $level, exception_type = COALESCE($exc_type, exception_type), message = COALESCE($msg, message), status = CASE WHEN status = 1 THEN 0 ELSE status END, updated_at = NOW() WHERE id = $issue_id`!
- **Rationale**: Look what that guarantees under arbitrary concurrency:
  - Concurrent new events with the same fingerprint: `ON CONFLICT (project_id, fingerprint) DO UPDATE` serializes cleanly in PostgreSQL with zero `RecordNotUnique` aborts, and every distinct inserted event atomically increments `event_count = event_count + 1`!
  - Concurrent duplicate deliveries of the exact same `(project_id, event_id)`: `ON CONFLICT (project_id, event_id) DO NOTHING RETURNING id` returns `nil` for the loser, so `event_count` is incremented **at most once**!
  - Reopens `resolved` (`status = 1`) to `unresolved` (`status = 0`) on new occurrences while preserving `ignored` (`status = 2`)!
- **Alternatives considered**: Rescue `ActiveRecord::RecordNotUnique` inside Ruby transactions — rejected because any `RecordNotUnique` inside a PostgreSQL transaction aborts the entire transaction block unless wrapped in savepoints (`requires_new: true`). Native `ON CONFLICT` avoids aborted transactions completely.

## Risks / Trade-offs

- **[Over-aggressive volatile stripping in message fingerprints]** → Restrict message normalization to UUIDs, hex digests (`>= 8` hex chars), ISO timestamps, and standalone numbers (`\b\d+\b`), and only fall back to message fingerprinting when no usable stack frames or explicit `fingerprint` exist.
- **[`sentry-ruby` background worker threads in test suite]** → Configure `config.background_worker_threads = 0` in SDK integration specs and route `Sentry::HTTPTransport` calls through Rack test dispatch so real `Sentry::Envelope` serialization, `X-Sentry-Auth` generation, and `gzip` thresholds are exercised deterministically without flaky sleeps.

## Migration Plan

No database schema migrations are required in Phase 2 — all tables and indexes were provisioned in Phase 1. Deploying Phase 2 adds routes, controller, and `lib/sentrace/{ingestion,issues}` modules.
