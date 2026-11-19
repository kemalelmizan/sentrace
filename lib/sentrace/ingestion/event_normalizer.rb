require "json"
require "time"

module Sentrace
  module Ingestion
    class EventNormalizer
      NormalizedEvent = Data.define(
        :event_id,
        :occurred_at,
        :received_at,
        :environment,
        :release,
        :platform,
        :level,
        :logger,
        :culprit,
        :exception_type,
        :issue_message,
        :fingerprint,
        :event_data,
        :raw_user,
        :raw_request
      )

      EVENT_ID_HEX = /\A[0-9a-f]{32}\z/
      SAFE_REQUEST_ID_REGEX = /\A[A-Za-z0-9._:-]{1,128}\z/
      ISSUE_MESSAGE_MAX_CHARS = 1024
      MAX_FINGERPRINT_ITEMS = 32
      MAX_FINGERPRINT_PART_BYTES = 256

      LEVEL_MAP = {
        "debug" => :debug,
        "info" => :info,
        "warn" => :warning,
        "warning" => :warning,
        "error" => :error,
        "fatal" => :fatal
      }.freeze

      class << self
        def normalize(raw_event, envelope_headers: {}, received_at: Time.current, config: Sentrace.configuration)
          new(config: config).normalize(raw_event, envelope_headers: envelope_headers, received_at: received_at)
        end

        def truncate_utf8_bytes(value, max_bytes)
          return nil if value.nil?

          str = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
          return str if str.bytesize <= max_bytes

          sliced = str.byteslice(0, max_bytes)
          until sliced.valid_encoding? || sliced.empty?
            sliced = sliced.byteslice(0, sliced.bytesize - 1)
          end
          sliced
        end
      end

      def initialize(config: Sentrace.configuration)
        @config = config
      end

      def normalize(raw_event, envelope_headers: {}, received_at: Time.current)
        unless raw_event.is_a?(Hash)
          raise EnvelopeParseError, "Event payload must be a JSON object"
        end

        event_id = extract_event_id(raw_event, envelope_headers)
        occurred_at = extract_timestamp(raw_event["timestamp"], fallback: received_at)
        level = normalize_level(raw_event["level"])

        exception_data = extract_exception(raw_event["exception"])
        message = extract_message(raw_event)
        culprit = truncate_chars(raw_event["culprit"] || raw_event["transaction"] || derive_culprit(exception_data), 512)

        summary_source = exception_data ? exception_data["value"] : message
        issue_message = truncate_chars(summary_source, ISSUE_MESSAGE_MAX_CHARS)

        raw_request_hash = raw_event["request"].is_a?(Hash) ? raw_event["request"] : nil
        tags = extract_tags(raw_event["tags"], raw_request: raw_request_hash)

        event_data = {
          "exception" => exception_data,
          "message" => message,
          "request" => nil,
          "breadcrumbs" => extract_breadcrumbs(raw_event["breadcrumbs"]),
          "tags" => tags,
          "contexts" => extract_contexts(raw_event["contexts"], raw_event["extra"]),
          "user" => nil
        }

        NormalizedEvent.new(
          event_id: event_id,
          occurred_at: occurred_at,
          received_at: received_at,
          environment: truncate_chars(raw_event["environment"], 64),
          release: truncate_chars(raw_event["release"], 128),
          platform: truncate_chars(raw_event["platform"], 32),
          level: level,
          logger: truncate_chars(raw_event["logger"], 128),
          culprit: culprit,
          exception_type: exception_data ? exception_data["type"] : nil,
          issue_message: issue_message,
          fingerprint: extract_fingerprint(raw_event["fingerprint"]),
          event_data: event_data,
          raw_user: raw_event["user"].is_a?(Hash) ? raw_event["user"] : nil,
          raw_request: raw_request_hash
        )
      end

      private
        def extract_event_id(raw_event, envelope_headers)
          candidate = raw_event["event_id"] || envelope_headers["event_id"]
          normalized = candidate.to_s.strip.delete("-").downcase
          unless normalized.match?(EVENT_ID_HEX)
            raise EnvelopeParseError, "Missing or invalid Sentry event_id"
          end

          normalized
        end

        def extract_timestamp(raw_timestamp, fallback:)
          return fallback if raw_timestamp.nil? || raw_timestamp.to_s.strip.empty?

          case raw_timestamp
          when Numeric
            Time.at(raw_timestamp).utc
          when String
            if raw_timestamp.match?(/\A\d+(?:\.\d+)?\z/)
              Time.at(raw_timestamp.to_f).utc
            else
              Time.iso8601(raw_timestamp).utc
            end
          else
            raise EnvelopeParseError, "Invalid event timestamp"
          end
        rescue ArgumentError, RangeError
          raise EnvelopeParseError, "Malformed event timestamp"
        end

        def normalize_level(raw_level)
          return :error if raw_level.nil?

          LEVEL_MAP.fetch(raw_level.to_s.strip.downcase, :error)
        end

        def extract_message(raw_event)
          raw_msg =
            if raw_event["message"].is_a?(String)
              raw_event["message"]
            elsif raw_event["message"].is_a?(Hash)
              raw_event.dig("message", "formatted") || raw_event.dig("message", "message")
            elsif raw_event["logentry"].is_a?(Hash)
              raw_event.dig("logentry", "formatted") || raw_event.dig("logentry", "message")
            end

          return nil if raw_msg.nil? || raw_msg.empty?

          self.class.truncate_utf8_bytes(raw_msg, @config.max_message_bytes)
        end

        def extract_exception(raw_exception)
          values =
            if raw_exception.is_a?(Hash) && raw_exception["values"].is_a?(Array)
              raw_exception["values"]
            elsif raw_exception.is_a?(Array)
              raw_exception
            end

          return nil if values.nil? || values.empty?

          primary = values.reverse.find { |item| item.is_a?(Hash) && (item["type"] || item["value"]) }
          return nil unless primary

          raw_frames =
            if primary.dig("stacktrace", "frames").is_a?(Array)
              primary.dig("stacktrace", "frames")
            else
              # Fall back to earliest cause carrying a stacktrace when wrapper reused backtrace
              with_trace = values.reverse.find { |item| item.is_a?(Hash) && item.dig("stacktrace", "frames").is_a?(Array) }
              with_trace ? with_trace.dig("stacktrace", "frames") : []
            end

          bounded_frames = raw_frames.select { |f| f.is_a?(Hash) }.last(@config.max_stack_frames).map do |frame|
            {
              "filename" => truncate_chars(frame["filename"] || frame["abs_path"], 512),
              "function" => truncate_chars(frame["function"], 255),
              "lineno" => frame["lineno"].is_a?(Integer) ? frame["lineno"] : nil,
              "colno" => frame["colno"].is_a?(Integer) ? frame["colno"] : nil,
              "in_app" => frame["in_app"] == true
            }.compact
          end

          result = {
            "type" => truncate_chars(primary["type"], 255),
            "value" => self.class.truncate_utf8_bytes(primary["value"], @config.max_message_bytes),
            "frames" => bounded_frames
          }
          mechanism = extract_mechanism(primary["mechanism"])
          result["mechanism"] = mechanism if mechanism
          result
        end

        def extract_mechanism(raw_mechanism)
          return nil unless raw_mechanism.is_a?(Hash)

          entry = {}
          type = truncate_chars(raw_mechanism["type"] || raw_mechanism[:type], 64)
          entry["type"] = type if type
          handled = raw_mechanism.key?("handled") ? raw_mechanism["handled"] : raw_mechanism[:handled]
          entry["handled"] = handled if handled == true || handled == false
          entry.empty? ? nil : entry
        end

        def derive_culprit(exception_data)
          return nil unless exception_data && exception_data["frames"].is_a?(Array)

          in_app_frame = exception_data["frames"].reverse.find { |f| f["in_app"] } || exception_data["frames"].last
          return nil unless in_app_frame

          parts = [ in_app_frame["filename"], in_app_frame["function"] ].compact
          parts.empty? ? nil : parts.join(" in ")
        end

        def extract_breadcrumbs(raw_breadcrumbs)
          items =
            if raw_breadcrumbs.is_a?(Hash) && raw_breadcrumbs["values"].is_a?(Array)
              raw_breadcrumbs["values"]
            elsif raw_breadcrumbs.is_a?(Array)
              raw_breadcrumbs
            else
              []
            end

          items.select { |b| b.is_a?(Hash) }.last(@config.max_breadcrumbs).map do |crumb|
            entry = {
              "timestamp" => normalize_breadcrumb_timestamp(crumb["timestamp"]),
              "type" => truncate_chars(crumb["type"], 64),
              "category" => truncate_chars(crumb["category"], 128),
              "level" => truncate_chars(crumb["level"], 32),
              "message" => self.class.truncate_utf8_bytes(crumb["message"], 1024)
            }.compact

            if crumb["data"].is_a?(Hash) && crumb["data"].any?
              entry["data"] = crumb["data"].first(16).to_h do |k, v|
                [
                  self.class.truncate_utf8_bytes(k.to_s, 64),
                  v.is_a?(Numeric) || v == true || v == false || v.nil? ? v : self.class.truncate_utf8_bytes(v.to_s, 256)
                ]
              end
            end

            entry
          end
        end

        def extract_tags(raw_tags, raw_request: nil)
          pairs =
            case raw_tags
            when Hash
              raw_tags.to_a
            when Array
              raw_tags.select { |item| item.is_a?(Array) && item.size == 2 }
            else
              []
            end

          tags = pairs.first(@config.max_tags).each_with_object({}) do |(raw_key, raw_val), acc|
            next if raw_key.nil?

            key = self.class.truncate_utf8_bytes(raw_key.to_s.strip, @config.max_tag_key_bytes)
            next if key.nil? || key.empty?

            acc[key] = raw_val.nil? ? nil : self.class.truncate_utf8_bytes(raw_val.to_s, @config.max_tag_value_bytes)
          end

          header_request_id = extract_safe_request_id(raw_request)
          if header_request_id && !tags.key?("request_id") && tags.size < @config.max_tags && "request_id".bytesize <= @config.max_tag_key_bytes
            tags["request_id"] = self.class.truncate_utf8_bytes(header_request_id, @config.max_tag_value_bytes)
          end

          tags
        end

        def extract_safe_request_id(raw_request)
          return nil unless raw_request.is_a?(Hash)

          candidate = nil
          headers = raw_request["headers"]
          case headers
          when Hash
            _, candidate = headers.find { |k, _| k.to_s.casecmp("x-request-id").zero? }
          when Array
            pair = headers.find { |item| item.is_a?(Array) && item.first.to_s.casecmp("x-request-id").zero? }
            candidate = pair[1] if pair
          end

          if candidate.nil? && raw_request["env"].is_a?(Hash)
            env_hash = raw_request["env"]
            candidate = env_hash["action_dispatch.request_id"] || env_hash["HTTP_X_REQUEST_ID"]
          end

          str = candidate.to_s.strip
          str.match?(SAFE_REQUEST_ID_REGEX) ? str : nil
        end

        def extract_contexts(raw_contexts, raw_extra = nil)
          source = raw_contexts.is_a?(Hash) ? raw_contexts.dup : {}
          if raw_extra.is_a?(Hash) && raw_extra.any? && !source.key?("extra") && !source.key?(:extra)
            source["extra"] = raw_extra
          end
          return {} if source.empty?

          bounded = {}
          source.each do |ctx_key, ctx_val|
            break if bounded.size >= @config.max_context_entries
            next unless ctx_val.is_a?(Hash)

            key_str = self.class.truncate_utf8_bytes(ctx_key.to_s, 64)
            next if key_str.nil? || key_str.empty?

            candidate = bounded.merge(key_str => bound_nested_value(ctx_val, depth: 0))
            if JSON.generate(candidate).bytesize <= @config.max_context_bytes
              bounded = candidate
            end
          end

          bounded
        end

        def bound_nested_value(value, depth:)
          return "[TRUNCATED]" if depth > 3

          case value
          when Hash
            value.first(16).to_h do |k, v|
              [ self.class.truncate_utf8_bytes(k.to_s, 64), bound_nested_value(v, depth: depth + 1) ]
            end
          when Array
            value.first(16).map { |v| bound_nested_value(v, depth: depth + 1) }
          when Numeric, TrueClass, FalseClass, NilClass
            value
          else
            self.class.truncate_utf8_bytes(value.to_s, 512)
          end
        end

        def normalize_breadcrumb_timestamp(raw_timestamp)
          case raw_timestamp
          when Numeric
            truncate_chars(raw_timestamp.to_s, 64)
          when String
            truncate_chars(raw_timestamp, 64)
          end
        end

        def extract_fingerprint(raw_fingerprint)
          return nil unless raw_fingerprint.is_a?(Array)

          cleaned = raw_fingerprint.first(MAX_FINGERPRINT_ITEMS).filter_map do |part|
            next unless part.is_a?(String) || part.is_a?(Symbol) || part.is_a?(Numeric)

            str = self.class.truncate_utf8_bytes(part.to_s.strip, MAX_FINGERPRINT_PART_BYTES)
            str unless str.nil? || str.empty?
          end

          cleaned.empty? ? nil : cleaned
        end

        def truncate_chars(value, max_chars)
          return nil if value.nil?

          str = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip
          return nil if str.empty?

          str.length > max_chars ? str[0, max_chars] : str
        end
    end
  end
end
