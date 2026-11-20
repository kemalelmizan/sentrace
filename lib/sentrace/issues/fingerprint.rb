require "json"
require "openssl"

module Sentrace
  module Issues
    class Fingerprint
      DEFAULT_PLACEHOLDER = "{{ default }}"
      MAX_FILENAME_INPUT_BYTES = 2048
      MAX_MESSAGE_INPUT_BYTES = 8192

      GEM_PATH_REGEX = %r{(?:\A|/)gems/([^/]+?)(?:-\d[\w.-]*)?/(.+)\z}
      RELEASE_PATH_REGEX = %r{(?:\A|/)(?:releases/[^/]+|current)/(.+)\z}
      APP_ROOT_SUBDIR_REGEX = %r{(?:\A|/)((?:app|config|db|lib)/.+)\z}
      HTTP_ORIGIN_REGEX = %r{\A(?:https?|file)://[^/]+}i
      BUNDLER_SCHEME_REGEX = %r{\A(?:webpack(?:-internal)?|vite|turbopack):///*}i
      JS_ASSET_DIGEST_REGEX = /[-.](?:[0-9a-f]{8,64}|(?=[A-Za-z0-9]{0,31}\d)(?=[A-Za-z0-9]{0,31}[A-Za-z])[A-Za-z0-9]{8,32})(?:\.digested)?(?=\.(?:m?js|cjs|jsx|tsx?|map)\z)/i
      ANONYMOUS_FUNCTION_NAMES = [ "?", "<anonymous>" ].freeze

      OBJECT_ADDRESS_REGEX = /0x[0-9a-f]{6,}/i
      ISO_TIMESTAMP_REGEX = /\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b/
      UUID_REGEX = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i
      LONG_HEX_REGEX = /\b[0-9a-f]{12,}\b/i
      NUMERIC_WITH_UNIT_REGEX = /(?<![A-Za-z0-9_])-?\d+(?:\.\d+)?(?:\s?%|\s?(?:pct|ns|us|µs|μs|ms|msecs?|secs?|seconds?|s|mins?|minutes?|m|hrs?|hours?|h|days?|d|[kmgtp]i?b|bytes?|b|khz|mhz|ghz|hz|rps|qps|px)\b)/i
      FLOAT_REGEX = /(?<![A-Za-z0-9_.])-?\d+\.\d+(?!\.\d)\b/
      INTEGER_REGEX = /\b\d+\b/

      class << self
        def compute(normalized_event, trust_domain = nil)
          new.compute(normalized_event, trust_domain)
        end

        def normalize_filename(raw_filename)
          return "" if raw_filename.nil?

          cleaned = Ingestion::EventNormalizer.truncate_utf8_bytes(raw_filename, MAX_FILENAME_INPUT_BYTES).to_s.strip
          return "" if cleaned.empty?

          cleaned = cleaned
            .sub(HTTP_ORIGIN_REGEX, "")
            .sub(BUNDLER_SCHEME_REGEX, "")
            .sub(/[?#].*\z/, "")
            .tr("\\", "/")
            .gsub(%r{/+}, "/")
            .sub(%r{\A(?:\./)+}, "")
            .sub(JS_ASSET_DIGEST_REGEX, "")
          return "" if cleaned.empty?

          if (gem_match = cleaned.match(GEM_PATH_REGEX))
            "gem:#{gem_match[1]}/#{gem_match[2]}"
          elsif (rel_match = cleaned.match(RELEASE_PATH_REGEX))
            rel_match[1]
          elsif (app_match = cleaned.match(APP_ROOT_SUBDIR_REGEX))
            app_match[1]
          else
            cleaned.sub(%r{\A/+}, "")
          end
        end

        def normalize_message(raw_message)
          return "" if raw_message.nil?

          Ingestion::EventNormalizer.truncate_utf8_bytes(raw_message, MAX_MESSAGE_INPUT_BYTES).to_s
            .gsub(ISO_TIMESTAMP_REGEX, "<timestamp>")
            .gsub(UUID_REGEX, "<uuid>")
            .gsub(OBJECT_ADDRESS_REGEX, "<hex>")
            .gsub(LONG_HEX_REGEX, "<hex>")
            .gsub(NUMERIC_WITH_UNIT_REGEX, "<num>")
            .gsub(FLOAT_REGEX, "<num>")
            .gsub(INTEGER_REGEX, "<num>")
            .gsub(/\s+/, " ")
            .strip
        end
      end

      def compute(normalized_event, trust_domain = nil)
        tokens = build_tokens(normalized_event)
        if trust_domain && !trust_domain.to_s.empty?
          tokens = [ "domain:#{trust_domain}", *tokens ]
        end
        canonical_payload = JSON.generate(tokens)
        OpenSSL::Digest::SHA256.hexdigest(canonical_payload)
      end

      private
        def build_tokens(normalized_event)
          explicit = extract_explicit_fingerprint(normalized_event)
          if explicit && explicit != [ DEFAULT_PLACEHOLDER ]
            return expand_explicit_fingerprint(explicit, normalized_event)
          end

          default_tokens(normalized_event)
        end

        def extract_explicit_fingerprint(normalized_event)
          fp =
            if normalized_event.respond_to?(:fingerprint)
              normalized_event.fingerprint
            elsif normalized_event.is_a?(Hash)
              normalized_event["fingerprint"] || normalized_event[:fingerprint]
            end

          return nil unless fp.is_a?(Array)

          cleaned = fp.first(Ingestion::EventNormalizer::MAX_FINGERPRINT_ITEMS).filter_map do |item|
            next unless item.is_a?(String) || item.is_a?(Symbol) || item.is_a?(Numeric)

            str = Ingestion::EventNormalizer.truncate_utf8_bytes(
              item.to_s.strip,
              Ingestion::EventNormalizer::MAX_FINGERPRINT_PART_BYTES
            )
            str unless str.nil? || str.empty?
          end
          cleaned.empty? ? nil : cleaned
        end

        def expand_explicit_fingerprint(explicit, normalized_event)
          if explicit.include?(DEFAULT_PLACEHOLDER)
            defaults = default_tokens(normalized_event)
            expanded = explicit.flat_map { |part| part == DEFAULT_PLACEHOLDER ? defaults : part }
            [ "hybrid", *expanded ]
          else
            [ "explicit", *explicit ]
          end
        end

        def default_tokens(normalized_event)
          event_data = extract_event_data(normalized_event)
          exception_hash = event_data["exception"].is_a?(Hash) ? event_data["exception"] : nil
          exception_type = extract_exception_type(normalized_event, exception_hash)
          frames = exception_hash && exception_hash["frames"].is_a?(Array) ? exception_hash["frames"] : []

          usable_frames = select_frames(frames)
          if usable_frames.any?
            frame_tokens = usable_frames.map { |frame| normalize_frame(frame) }
            [ "exception-frames", exception_type.to_s, *frame_tokens ]
          else
            raw_msg =
              (exception_hash && exception_hash["value"]) ||
              event_data["message"] ||
              extract_issue_message(normalized_event)
            [ "message", exception_type.to_s, self.class.normalize_message(raw_msg) ]
          end
        end

        def select_frames(frames)
          valid_frames = frames.select do |f|
            f.is_a?(Hash) && (!f["filename"].to_s.strip.empty? || !f["function"].to_s.strip.empty?)
          end
          return [] if valid_frames.empty?

          in_app_frames = valid_frames.select { |f| f["in_app"] == true }
          in_app_frames.any? ? in_app_frames : valid_frames
        end

        def normalize_frame(frame)
          file = self.class.normalize_filename(frame["filename"])
          func = normalize_function(frame["function"])
          if !func.empty?
            "#{file}:#{func}"
          elsif frame["lineno"] && frame["colno"]
            "#{file}:line:#{frame["lineno"]}:col:#{frame["colno"]}"
          elsif frame["lineno"]
            "#{file}:line:#{frame["lineno"]}"
          else
            file
          end
        end

        def normalize_function(raw_function)
          return "" if raw_function.nil?

          cleaned = raw_function.to_s
            .gsub(OBJECT_ADDRESS_REGEX, "<hex>")
            .gsub(/\s+/, " ")
            .strip
          ANONYMOUS_FUNCTION_NAMES.include?(cleaned) ? "" : cleaned
        end

        def extract_event_data(normalized_event)
          if normalized_event.respond_to?(:event_data) && normalized_event.event_data.is_a?(Hash)
            normalized_event.event_data
          elsif normalized_event.is_a?(Hash)
            (normalized_event["event_data"] || normalized_event[:event_data] || normalized_event).to_h
          else
            {}
          end
        end

        def extract_exception_type(normalized_event, exception_hash)
          if normalized_event.respond_to?(:exception_type) && normalized_event.exception_type
            normalized_event.exception_type
          elsif exception_hash && exception_hash["type"]
            exception_hash["type"]
          elsif normalized_event.is_a?(Hash)
            normalized_event["exception_type"] || normalized_event[:exception_type]
          end
        end

        def extract_issue_message(normalized_event)
          if normalized_event.respond_to?(:issue_message)
            normalized_event.issue_message
          elsif normalized_event.is_a?(Hash)
            normalized_event["issue_message"] || normalized_event[:issue_message] || normalized_event["message"]
          end
        end
    end
  end
end
