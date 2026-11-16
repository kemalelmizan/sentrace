require "json"
require "openssl"

module Sentrace
  module Issues
    class Fingerprint
      DEFAULT_PLACEHOLDER = "{{ default }}"

      GEM_PATH_REGEX = %r{(?:\A|/)gems/([^/]+?)(?:-\d[\w.-]*)?/(.+)\z}
      RELEASE_PATH_REGEX = %r{(?:\A|/)(?:releases/[^/]+|current)/(.+)\z}
      APP_ROOT_SUBDIR_REGEX = %r{(?:\A|/)((?:app|config|db|lib)/.+)\z}

      OBJECT_ADDRESS_REGEX = /0x[0-9a-f]{6,}/i
      ISO_TIMESTAMP_REGEX = /\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b/
      UUID_REGEX = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i
      LONG_HEX_REGEX = /\b[0-9a-f]{12,}\b/i
      INTEGER_REGEX = /\b\d+\b/

      class << self
        def compute(normalized_event)
          new.compute(normalized_event)
        end

        def normalize_filename(raw_filename)
          return "" if raw_filename.nil?

          cleaned = raw_filename.to_s.tr("\\", "/").strip.gsub(%r{/+}, "/")
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

          raw_message.to_s
            .gsub(ISO_TIMESTAMP_REGEX, "<timestamp>")
            .gsub(UUID_REGEX, "<uuid>")
            .gsub(OBJECT_ADDRESS_REGEX, "<hex>")
            .gsub(LONG_HEX_REGEX, "<hex>")
            .gsub(INTEGER_REGEX, "<int>")
            .gsub(/\s+/, " ")
            .strip
        end
      end

      def compute(normalized_event)
        tokens = build_tokens(normalized_event)
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

          cleaned = fp.filter_map do |item|
            str = item.to_s.strip
            str unless str.empty?
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
          elsif frame["lineno"]
            "#{file}:line:#{frame["lineno"]}"
          else
            file
          end
        end

        def normalize_function(raw_function)
          return "" if raw_function.nil?

          raw_function.to_s
            .gsub(OBJECT_ADDRESS_REGEX, "<hex>")
            .gsub(/\s+/, " ")
            .strip
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
