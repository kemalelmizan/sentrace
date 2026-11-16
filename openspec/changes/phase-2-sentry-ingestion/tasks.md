# Tasks

## 1. Envelope Parsing, Event Normalization & Privacy Sanitization

- [x] 1.1 Implement `Sentrace::Ingestion::EnvelopeParser` (`lib/sentrace/ingestion/envelope_parser.rb`) supporting multi-item envelopes, byte-accurate `length` framing, `event` extraction, and zero-allocation discarding of `transaction`, `session`, `sessions`, `attachment`, `client_report`, `profile`, `replay_event`, `replay_recording`, and unknown item types, and verify unit specs cover valid, binary-attachment, and malformed envelopes
- [x] 1.2 Implement `Sentrace::Ingestion::EventNormalizer` (`lib/sentrace/ingestion/event_normalizer.rb`) and `Sentrace::Ingestion::Sanitizer` (`lib/sentrace/ingestion/sanitizer.rb`) enforcing field bounds (`max_message_bytes`, `max_stack_frames`, `max_breadcrumbs`, `max_tags`, `max_tag_key_bytes`, `max_tag_value_bytes`, `max_context_entries`, `max_context_bytes`), default sensitive-field exclusions (bodies, cookies, auth headers, IPs, emails/names, env vars), recursive `redact_fields`/card scrubbing, per-project HMAC-SHA256 user `id_hash`, and custom host `sanitizer` hooks, and verify unit specs pass

## 2. Deterministic Fingerprinting, Atomic Issue Grouping & Persistence

- [x] 2.1 Implement `Sentrace::Issues::Fingerprint` (`lib/sentrace/issues/fingerprint.rb`) for deterministic 64-char SHA-256 digests across explicit `fingerprint`, `exception + normalized in-app frames` (normalizing release/bundle paths and excluding `environment`), and volatile-stripped message fallbacks, and verify standalone unit specs pass
- [x] 2.2 Implement `Sentrace::Issues::Grouper` (`lib/sentrace/issues/grouper.rb`) and `Sentrace::Ingestion::Processor` (`lib/sentrace/ingestion/processor.rb`) using PostgreSQL `ON CONFLICT` upserts for concurrency-safe `(project_id, fingerprint)` issue creation/counting, `resolved -> unresolved` regression reopening, and `(project_id, event_id)` deduplication, and verify persistence, deduplication, and multi-threaded concurrency specs pass

## 3. Ingestion HTTP Endpoint & Real `sentry-ruby` SDK Compatibility

- [ ] 3.1 Mount `POST /api/:project_id/envelope` on `Sentrace::Engine` (`config/routes.rb`, `app/controllers/sentrace/ingestion_controller.rb`) enforcing pre-parse `max_envelope_size` (`413`), streaming `gzip` inflation bounds (`413`), DSN public-key authentication (`401`), malformed-payload `400` responses, and non-leaking error bodies, and verify request and storage specs pass
- [ ] 3.2 Add end-to-end SDK compatibility specs (`spec/integration/sentry_ruby_compatibility_spec.rb`) using a real `sentry-ruby` (`5.28.1`) client to verify exception capture, message capture, breadcrumbs, stack traces, release/environment attribution, gzip envelopes, and non-error item discarding, and document pinned SDK compatibility in `README.md`

## Workflow follow-up

- Run `rtk openspec validate --all --strict --no-interactive`, verify full RSpec + RuboCop suites, and archive `phase-2-sentry-ingestion`.
- Propose `phase-3-mcp-local-server` next following `SPEC.md` §16.
