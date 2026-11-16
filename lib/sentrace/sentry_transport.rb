require "json"

module Sentrace
  sentry_base = defined?(::Sentry::Transport) ? ::Sentry::Transport : Object

  class SentryTransport < sentry_base
    SUPPORTED_ERROR_TYPES = [ nil, "", "event" ].freeze

    def initialize(configuration)
      if defined?(::Sentry::Transport) && self.class < ::Sentry::Transport
        super
      else
        @dsn = configuration.respond_to?(:dsn) ? configuration.dsn : nil
      end
    end

    def send_envelope(envelope)
      return nil unless envelope && envelope.respond_to?(:items)

      if respond_to?(:reject_rate_limited_items, true)
        reject_rate_limited_items(envelope)
      end

      raw_headers = envelope.respond_to?(:headers) && envelope.headers.is_a?(Hash) ? envelope.headers : {}
      explicit_project_id = resolve_target_project_id

      envelope.items.each do |item|
        next unless error_event_item?(item)

        payload = extract_payload_hash(item)
        next unless payload

        CaptureDispatcher.dispatch_raw_event(
          payload,
          envelope_headers: raw_headers,
          explicit_project_id: explicit_project_id,
          apply_sampling: false,
          apply_before_send: false
        )
      end

      nil
    end

    def send_data(_data, _options = {})
      # Intentional no-op: Sentrace::SentryTransport never opens network sockets.
      nil
    end

    def flush
      Sentrace.flush(timeout: 2.0)
    end

    private
      def error_event_item?(item)
        item_type =
          if item.respond_to?(:type)
            item.type
          elsif item.respond_to?(:headers) && item.headers.is_a?(Hash)
            item.headers[:type] || item.headers["type"]
          end
        return false unless SUPPORTED_ERROR_TYPES.include?(item_type&.to_s)

        if item.respond_to?(:payload) && item.payload.is_a?(Hash)
          payload_type = item.payload[:type] || item.payload["type"]
          return false unless SUPPORTED_ERROR_TYPES.include?(payload_type&.to_s)
        end

        true
      end

      def extract_payload_hash(item)
        raw = item.respond_to?(:payload) ? item.payload : nil
        case raw
        when Hash
          raw
        when String
          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : nil
        else
          raw.respond_to?(:to_hash) ? raw.to_hash : nil
        end
      rescue JSON::ParserError
        nil
      end

      def resolve_target_project_id
        # Prefer explicit Sentrace configuration (`project_id` / `project_slug`) when set;
        # otherwise fall back to the numeric project ID embedded in Sentry's DSN.
        return nil if Sentrace.configuration.target_project_configured?
        return nil unless @dsn

        dsn_project_id =
          if @dsn.respond_to?(:project_id)
            @dsn.project_id
          else
            Dsn.parse(@dsn.to_s).project_id
          end
        id_int = dsn_project_id.to_i
        id_int.positive? ? id_int : nil
      rescue InvalidDsnError, StandardError
        nil
      end
  end
end
