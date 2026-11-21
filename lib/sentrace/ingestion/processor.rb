module Sentrace
  module Ingestion
    class Processor
      EnvelopeResult = Data.define(:primary_event_id, :accepted_event_ids, :duplicate_event_ids, :discarded_count)

      class << self
        def process_raw_envelope(
          raw_body,
          project:,
          received_at: Time.current,
          config: Sentrace.configuration,
          ingestion_source: "http_dsn",
          trusted_http_key: false,
          before_persist: nil
        )
          new(config: config).process_raw_envelope(
            raw_body,
            project: project,
            received_at: received_at,
            ingestion_source: ingestion_source,
            trusted_http_key: trusted_http_key,
            before_persist: before_persist
          )
        end

        def ingest_event(
          raw_event,
          project:,
          envelope_headers: {},
          received_at: Time.current,
          config: Sentrace.configuration,
          ingestion_source: "in_process",
          trusted_http_key: false
        )
          new(config: config).ingest_event(
            raw_event,
            project: project,
            envelope_headers: envelope_headers,
            received_at: received_at,
            ingestion_source: ingestion_source,
            trusted_http_key: trusted_http_key
          )
        end
      end

      def initialize(config: Sentrace.configuration)
        @config = config
      end

      def process_raw_envelope(raw_body, project:, received_at: Time.current, ingestion_source: "http_dsn", trusted_http_key: false, before_persist: nil)
        parsed = EnvelopeParser.parse(
          raw_body,
          max_items: @config.max_envelope_items,
          max_events: @config.max_events_per_envelope
        )
        before_persist.call(parsed.events.size) if before_persist && parsed.events.size > 1
        accepted_ids = []
        duplicate_ids = []

        parsed.events.each do |raw_event|
          result = ingest_event(
            raw_event,
            project: project,
            envelope_headers: parsed.headers,
            received_at: received_at,
            ingestion_source: ingestion_source,
            trusted_http_key: trusted_http_key
          )
          if result.duplicate
            duplicate_ids << result.event_id
          else
            accepted_ids << result.event_id
          end
        end

        primary_id = accepted_ids.first || duplicate_ids.first || extract_valid_header_event_id(parsed.headers)

        EnvelopeResult.new(
          primary_event_id: primary_id,
          accepted_event_ids: accepted_ids,
          duplicate_event_ids: duplicate_ids,
          discarded_count: parsed.discarded_item_types.size
        )
      end

      def ingest_event(raw_event, project:, envelope_headers: {}, received_at: Time.current, ingestion_source: "in_process", trusted_http_key: false)
        project_id = project.is_a?(Integer) ? project : project.id
        normalized = EventNormalizer.normalize(
          raw_event,
          envelope_headers: envelope_headers,
          received_at: received_at,
          config: @config,
          ingestion_source: ingestion_source
        )

        # Fast-path read check via unique index (project_id, event_id) before running sanitizer or writes
        if Event.exists?(project_id: project_id, event_id: normalized.event_id)
          return Issues::Grouper::PersistResult.new(
            event_id: normalized.event_id,
            event_record_id: nil,
            issue_id: nil,
            duplicate: true
          )
        end

        sanitized = Sanitizer.sanitize(
          normalized,
          project_id: project_id,
          config: @config,
          trusted_http_key: trusted_http_key
        )
        # Domain-separate public-key-only http_dsn fingerprints so untrusted browser callers
        # can never collide with, overwrite, or reopen trusted in_process backend issues.
        trust_domain = (sanitized.event_data["ingestion_source"] == "http_dsn" && !trusted_http_key) ? "http_dsn" : nil
        fingerprint = Issues::Fingerprint.compute(sanitized, trust_domain)

        Issues::Grouper.persist!(
          project_id: project_id,
          normalized_event: sanitized,
          fingerprint: fingerprint,
          now: received_at
        )
      end

      private
        def extract_valid_header_event_id(headers)
          candidate = headers["event_id"].to_s.strip.delete("-").downcase
          candidate.match?(EventNormalizer::EVENT_ID_HEX) ? candidate : nil
        end
    end
  end
end
