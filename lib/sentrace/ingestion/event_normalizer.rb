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
      ALLOWED_INGESTION_SOURCES = %w[in_process http_dsn].freeze
      ISSUE_MESSAGE_MAX_CHARS = 1024
      MAX_FINGERPRINT_ITEMS = 32
      MAX_FINGERPRINT_PART_BYTES = 256
      PRE_SANITIZE_MAX_BYTES = 8192
      MAX_RAW_ARRAY_SCAN = 256
      MAX_SAFE_INTEGER = (1 << 63) - 1
      MIN_SAFE_INTEGER = -(1 << 63)
      MAX_TIMESTAMP_STRING_BYTES = 64
      MAX_BREADCRUMB_DATA_NODES = 256
      MAX_BREADCRUMB_COLLECTION_ITEMS = 8
      MAX_BREADCRUMB_DEPTH = 2
      MAX_CONTEXT_NODES = 512
      ANSI_ESCAPE_REGEX = /\e(?:\[[0-9;?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\))/
      UNSAFE_UNICODE_REGEX = /[\p{Cf}\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u2065\u2800\u3164\uFE00-\uFE0F\uFFA0\uFFF9-\uFFFB\u{E0000}-\u{E007F}\u{E0100}-\u{E01EF}]/
      DISALLOWED_MULTILINE_CONTROLS_REGEX = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u0080-\u009F]/
      DISALLOWED_SINGLELINE_CONTROLS_REGEX = /[\x00-\x1F\x7F\u0080-\u009F\u2028\u2029]/

      LEVEL_MAP = {
        "debug" => :debug,
        "info" => :info,
        "warn" => :warning,
        "warning" => :warning,
        "error" => :error,
        "fatal" => :fatal
      }.freeze

      class << self
        def normalize(
          raw_event,
          envelope_headers: {},
          received_at: Time.current,
          config: Sentrace.configuration,
          ingestion_source: "in_process"
        )
          new(config: config).normalize(
            raw_event,
            envelope_headers: envelope_headers,
            received_at: received_at,
            ingestion_source: ingestion_source
          )
        end

        def strip_unsafe_characters(value, allow_newlines: false)
          return nil if value.nil?

          str = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
          str.gsub!(ANSI_ESCAPE_REGEX, "")
          str.gsub!(UNSAFE_UNICODE_REGEX, "")
          if allow_newlines
            str.gsub!("\r\n", "\n")
            str.tr!("\r\u2028\u2029", "\n\n\n")
            str.gsub!(DISALLOWED_MULTILINE_CONTROLS_REGEX, "")
          else
            str.gsub!(DISALLOWED_SINGLELINE_CONTROLS_REGEX, " ")
          end
          str
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

        def scrub_and_truncate_bytes(value, max_bytes, allow_newlines: true)
          return nil if value.nil?

          pre_limit = [ max_bytes.to_i, PRE_SANITIZE_MAX_BYTES ].max
          bounded = truncate_utf8_bytes(value, pre_limit)
          cleaned = strip_unsafe_characters(bounded, allow_newlines: allow_newlines)
          redacted = Sanitizer.redact_inline_secrets(cleaned)
          truncate_utf8_bytes(redacted, max_bytes)
        end
      end

      def initialize(config: Sentrace.configuration)
        @config = config
      end

      def normalize(raw_event, envelope_headers: {}, received_at: Time.current, ingestion_source: "in_process")
        unless raw_event.is_a?(Hash)
          raise EnvelopeParseError, "Event payload must be a JSON object"
        end

        validated_source = ALLOWED_INGESTION_SOURCES.include?(ingestion_source.to_s) ? ingestion_source.to_s : "in_process"
        event_id = extract_event_id(raw_event, envelope_headers)
        occurred_at = extract_timestamp(raw_event["timestamp"], fallback: received_at, ingestion_source: validated_source)
        level = normalize_level(raw_event["level"])

        exception_data = extract_exception(raw_event["exception"])
        message = extract_message(raw_event)
        culprit = truncate_chars(raw_event["culprit"] || raw_event["transaction"] || derive_culprit(exception_data), 512)

        summary_source = exception_data ? exception_data["value"] : message
        issue_message = truncate_multiline_chars(summary_source, ISSUE_MESSAGE_MAX_CHARS)

        raw_request_hash = raw_event["request"].is_a?(Hash) ? raw_event["request"] : nil
        tags = extract_tags(raw_event["tags"], raw_request: raw_request_hash)

        event_data = {
          "ingestion_source" => validated_source,
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

        def extract_timestamp(raw_timestamp, fallback:, ingestion_source: "in_process")
          fallback_utc = fallback.utc
          return fallback_utc if raw_timestamp.nil?
          return fallback_utc if raw_timestamp.is_a?(String) && raw_timestamp.strip.empty?

          max_skew =
            if ingestion_source == "http_dsn"
              0
            elsif @config.respond_to?(:max_future_clock_skew) && !@config.max_future_clock_skew.nil?
              @config.max_future_clock_skew
            else
              0
            end
          max_future = fallback_utc + max_skew
          min_past = fallback_utc - (@config.retention_period * 2)

          parsed =
            case raw_timestamp
            when Integer
              return fallback_utc if raw_timestamp > MAX_SAFE_INTEGER
              return min_past if raw_timestamp < MIN_SAFE_INTEGER

              Time.at(raw_timestamp).utc
            when Float
              raise EnvelopeParseError, "Invalid event timestamp" unless raw_timestamp.finite?
              return fallback_utc if raw_timestamp > MAX_SAFE_INTEGER
              return min_past if raw_timestamp < MIN_SAFE_INTEGER

              Time.at(raw_timestamp).utc
            when Numeric
              Time.at(raw_timestamp).utc
            when String
              raise EnvelopeParseError, "Malformed event timestamp" if raw_timestamp.bytesize > MAX_TIMESTAMP_STRING_BYTES

              if raw_timestamp.match?(/\A\d+(?:\.\d+)?\z/)
                numeric_val = raw_timestamp.to_f
                raise EnvelopeParseError, "Malformed event timestamp" unless numeric_val.finite?
                return fallback_utc if numeric_val > MAX_SAFE_INTEGER

                Time.at(numeric_val).utc
              else
                Time.iso8601(raw_timestamp).utc
              end
            else
              raise EnvelopeParseError, "Invalid event timestamp"
            end

          return fallback_utc if parsed > max_future
          return min_past if parsed < min_past

          parsed
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

          self.class.scrub_and_truncate_bytes(raw_msg, @config.max_message_bytes, allow_newlines: true)
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

          bounded_frames = take_last_hashes(raw_frames, @config.max_stack_frames).map do |frame|
            {
              "filename" => truncate_chars(frame["filename"] || frame["abs_path"], 512),
              "function" => truncate_chars(frame["function"], 255),
              "lineno" => safe_int_or_nil(frame["lineno"]),
              "colno" => safe_int_or_nil(frame["colno"]),
              "in_app" => frame["in_app"] == true
            }.compact
          end

          result = {
            "type" => truncate_chars(primary["type"], 255),
            "value" => self.class.scrub_and_truncate_bytes(primary["value"], @config.max_message_bytes, allow_newlines: true),
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

          candidates = take_last_hashes(items, @config.max_breadcrumbs)
          return [] if candidates.empty?

          max_bytes = @config.respond_to?(:max_breadcrumbs_bytes) && @config.max_breadcrumbs_bytes ? @config.max_breadcrumbs_bytes.to_i : 24_576
          node_budget = { remaining: MAX_BREADCRUMB_DATA_NODES }
          kept_reversed = []
          total_bytes = 2 # "[]"

          candidates.reverse_each do |crumb|
            break if (max_bytes - total_bytes) < 8

            entry = {
              "timestamp" => normalize_breadcrumb_timestamp(crumb["timestamp"]),
              "type" => truncate_chars(crumb["type"], 64),
              "category" => truncate_chars(crumb["category"], 128),
              "level" => truncate_chars(crumb["level"], 32),
              "message" => self.class.scrub_and_truncate_bytes(crumb["message"], 1024, allow_newlines: true)
            }.compact

            if crumb["data"].is_a?(Hash) && crumb["data"].any? && node_budget[:remaining].positive?
              data_hash = {}
              crumb["data"].first(16).each do |k, v|
                break if node_budget[:remaining] <= 0

                clean_k = self.class.scrub_and_truncate_bytes(k.to_s, 64, allow_newlines: false)
                next if clean_k.nil? || clean_k.empty?

                data_hash[clean_k] = bound_breadcrumb_data_value(v, depth: 1, node_budget: node_budget)
              end
              entry["data"] = data_hash if data_hash.any?
            end

            next if entry.empty?

            separator_bytes = kept_reversed.empty? ? 0 : 1
            entry_bytes = JSON.generate(entry).bytesize
            if (total_bytes + separator_bytes + entry_bytes) <= max_bytes
              kept_reversed << entry
              total_bytes += separator_bytes + entry_bytes
            elsif entry.key?("data")
              without_data = entry.except("data")
              next if without_data.empty?

              reduced_bytes = JSON.generate(without_data).bytesize
              if (total_bytes + separator_bytes + reduced_bytes) <= max_bytes
                kept_reversed << without_data
                total_bytes += separator_bytes + reduced_bytes
              end
            end
          end

          kept_reversed.reverse!
        end

        def extract_tags(raw_tags, raw_request: nil)
          tags = {}
          max_scan = [ @config.max_tags * 4, MAX_RAW_ARRAY_SCAN ].max
          scanned = 0

          case raw_tags
          when Hash
            raw_tags.each do |raw_key, raw_val|
              break if tags.size >= @config.max_tags || scanned >= max_scan
              scanned += 1
              add_normalized_tag!(tags, raw_key, raw_val)
            end
          when Array
            raw_tags.each do |item|
              break if tags.size >= @config.max_tags || scanned >= max_scan
              scanned += 1
              next unless item.is_a?(Array) && item.size == 2

              add_normalized_tag!(tags, item[0], item[1])
            end
          end

          header_request_id = extract_safe_request_id(raw_request)
          if header_request_id && !tags.key?("request_id") && tags.size < @config.max_tags && "request_id".bytesize <= @config.max_tag_key_bytes
            tags["request_id"] = self.class.truncate_utf8_bytes(header_request_id, @config.max_tag_value_bytes)
          end

          tags
        end

        def add_normalized_tag!(tags, raw_key, raw_val)
          return if raw_key.nil?

          cleaned_key = self.class.strip_unsafe_characters(raw_key.to_s, allow_newlines: false).to_s.strip
          key = self.class.truncate_utf8_bytes(cleaned_key, @config.max_tag_key_bytes)
          return if key.nil? || key.empty?

          val_str =
            if raw_val.nil?
              nil
            elsif raw_val.is_a?(Hash) || raw_val.is_a?(Array)
              Sanitizer.redact_structure_to_string(raw_val, config: @config)
            elsif raw_val.is_a?(Numeric)
              safe_numeric_string(raw_val)
            else
              raw_val.to_s
            end

          tags[key] = val_str.nil? ? nil : self.class.scrub_and_truncate_bytes(val_str, @config.max_tag_value_bytes, allow_newlines: false)
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
          max_bytes = @config.max_context_bytes
          max_scan = [ @config.max_context_entries * 2, 64 ].max
          node_budget = { remaining: MAX_CONTEXT_NODES }
          scanned = 0
          total_bytes = 2 # "{}"

          source.each do |ctx_key, ctx_val|
            break if bounded.size >= @config.max_context_entries || scanned >= max_scan
            break if (max_bytes - total_bytes) < 8
            break if node_budget[:remaining] <= 0

            scanned += 1
            next unless ctx_val.is_a?(Hash)

            cleaned_key = self.class.strip_unsafe_characters(ctx_key.to_s, allow_newlines: false).to_s.strip
            key_str = self.class.truncate_utf8_bytes(cleaned_key, 64)
            next if key_str.nil? || key_str.empty? || bounded.key?(key_str)

            bounded_val = bound_nested_value(ctx_val, depth: 0, node_budget: node_budget)
            entry_bytes = JSON.generate(key_str => bounded_val).bytesize - 2
            separator_bytes = bounded.empty? ? 0 : 1
            if (total_bytes + separator_bytes + entry_bytes) <= max_bytes
              bounded[key_str] = bounded_val
              total_bytes += separator_bytes + entry_bytes
            end
          end

          bounded
        end

        def bound_nested_value(value, depth:, node_budget: nil)
          if node_budget
            node_budget[:remaining] -= 1
            return "[TRUNCATED]" if node_budget[:remaining] < 0
          end
          return "[TRUNCATED]" if depth > 3

          case value
          when Hash
            out = {}
            value.first(16).each do |k, v|
              break if node_budget && node_budget[:remaining] <= 0

              cleaned_k = self.class.strip_unsafe_characters(k.to_s, allow_newlines: false).to_s
              out[self.class.truncate_utf8_bytes(cleaned_k, 64)] = bound_nested_value(v, depth: depth + 1, node_budget: node_budget)
            end
            out
          when Array
            out = []
            value.first(16).each do |v|
              break if node_budget && node_budget[:remaining] <= 0

              out << bound_nested_value(v, depth: depth + 1, node_budget: node_budget)
            end
            out
          when Numeric
            safe_numeric_value(value)
          when TrueClass, FalseClass, NilClass
            value
          else
            self.class.scrub_and_truncate_bytes(value.to_s, 512, allow_newlines: true)
          end
        end

        def bound_breadcrumb_data_value(value, depth: 1, node_budget: nil)
          if node_budget
            node_budget[:remaining] -= 1
            return "[TRUNCATED]" if node_budget[:remaining] < 0
          end
          return "[TRUNCATED]" if depth > MAX_BREADCRUMB_DEPTH

          case value
          when Hash
            out = {}
            value.first(MAX_BREADCRUMB_COLLECTION_ITEMS).each do |k, v|
              break if node_budget && node_budget[:remaining] <= 0

              cleaned_k = self.class.strip_unsafe_characters(k.to_s, allow_newlines: false).to_s
              out[self.class.truncate_utf8_bytes(cleaned_k, 64)] = bound_breadcrumb_data_value(v, depth: depth + 1, node_budget: node_budget)
            end
            out
          when Array
            out = []
            value.first(MAX_BREADCRUMB_COLLECTION_ITEMS).each do |v|
              break if node_budget && node_budget[:remaining] <= 0

              out << bound_breadcrumb_data_value(v, depth: depth + 1, node_budget: node_budget)
            end
            out
          when Numeric
            safe_numeric_value(value)
          when TrueClass, FalseClass, NilClass
            value
          else
            self.class.scrub_and_truncate_bytes(value.to_s, 256, allow_newlines: false)
          end
        end

        def take_last_hashes(items, limit)
          return [] unless items.is_a?(Array) && limit.positive?

          max_scan = [ limit * 4, MAX_RAW_ARRAY_SCAN ].max
          collected = []
          scanned = 0
          items.reverse_each do |item|
            break if collected.size >= limit || scanned >= max_scan
            scanned += 1
            collected << item if item.is_a?(Hash)
          end
          collected.reverse!
        end

        def safe_int_or_nil(val)
          return nil unless val.is_a?(Integer)
          return nil if val > MAX_SAFE_INTEGER || val < MIN_SAFE_INTEGER

          val
        end

        def safe_numeric_value(val)
          case val
          when Integer
            (val > MAX_SAFE_INTEGER || val < MIN_SAFE_INTEGER) ? "[OVERFLOW_INT]" : val
          when Float
            val.finite? ? val : nil
          else
            val
          end
        end

        def safe_numeric_string(val)
          safe = safe_numeric_value(val)
          safe.nil? ? nil : safe.to_s
        end

        def normalize_breadcrumb_timestamp(raw_timestamp)
          case raw_timestamp
          when Numeric
            safe_str = safe_numeric_string(raw_timestamp)
            safe_str ? truncate_chars(safe_str, 64) : nil
          when String
            truncate_chars(raw_timestamp, 64)
          end
        end

        def extract_fingerprint(raw_fingerprint)
          return nil unless raw_fingerprint.is_a?(Array)

          cleaned = raw_fingerprint.first(MAX_FINGERPRINT_ITEMS).filter_map do |part|
            next unless part.is_a?(String) || part.is_a?(Symbol) || part.is_a?(Numeric)

            raw_str = part.is_a?(Numeric) ? safe_numeric_string(part) : part.to_s
            next if raw_str.nil?

            sanitized_part = self.class.strip_unsafe_characters(raw_str, allow_newlines: false).to_s.strip
            str = self.class.truncate_utf8_bytes(sanitized_part, MAX_FINGERPRINT_PART_BYTES)
            str unless str.nil? || str.empty?
          end

          cleaned.empty? ? nil : cleaned
        end

        def truncate_chars(value, max_chars)
          return nil if value.nil?

          str = self.class.strip_unsafe_characters(value, allow_newlines: false).to_s.strip
          return nil if str.empty?

          str.length > max_chars ? str[0, max_chars] : str
        end

        def truncate_multiline_chars(value, max_chars)
          return nil if value.nil?

          str = self.class.strip_unsafe_characters(value, allow_newlines: true).to_s.strip
          return nil if str.empty?

          str.length > max_chars ? str[0, max_chars] : str
        end
    end
  end
end
