module Sentrace
  module Ingestion
    class Processor
      EnvelopeResult = Data.define(:primary_event_id, :accepted_event_ids, :duplicate_event_ids, :discarded_count)

      class << self
        def process_raw_envelope(raw_body, project:, received_at: Time.current, config: Sentrace.configuration)
          new(config: config).process_raw_envelope(raw_body, project: project, received_at: received_at)
        end

        def ingest_event(raw_event, project:, envelope_headers: {}, received_at: Time.current, config: Sentrace.configuration)
          new(config: config).ingest_event(
            raw_event,
            project: project,
            envelope_headers: envelope_headers,
            received_at: received_at
          )
        end
      end

      def initialize(config: Sentrace.configuration)
        @config = config
      end

      def process_raw_envelope(raw_body, project:, received_at: Time.current)
        parsed = EnvelopeParser.parse(raw_body)
        accepted_ids = []
        duplicate_ids = []

        parsed.events.each do |raw_event|
          result = ingest_event(
            raw_event,
            project: project,
            envelope_headers: parsed.headers,
            received_at: received_at
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

      def ingest_event(raw_event, project:, envelope_headers: {}, received_at: Time.current)
        project_id = project.is_a?(Integer) ? project : project.id
        normalized = EventNormalizer.normalize(
          raw_event,
          envelope_headers: envelope_headers,
          received_at: received_at,
          config: @config
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

        sanitized = Sanitizer.sanitize(normalized, project_id: project_id, config: @config)
        fingerprint = Issues::Fingerprint.compute(sanitized)

        Issues::Grouper.persist!(
          project_id: project_id,
          normalized_event: sanitized,
          fingerprint: fingerprint
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
