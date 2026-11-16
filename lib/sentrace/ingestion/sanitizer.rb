require "json"
require "openssl"
require "uri"

module Sentrace
  module Ingestion
    class Sanitizer
      REDACTED = "[REDACTED]"

      FORBIDDEN_CONTEXT_KEYS = %w[
        env
        environment
        environment_variables
        rack_env
        headers
        cookies
        session
      ].freeze

      ALWAYS_REDACT_PATTERNS = %w[
        password
        passwd
        secret
        token
        authorization
        cookie
        session_id
        credit_card
        card_number
        cvv
        cvc
        api_key
        ip_address
        remote_addr
        remote_ip
        client_ip
      ].freeze

      BEARER_HEADER_REGEX = /\bBearer\s+[A-Za-z0-9\-._~+\/]+=*/i
      PAN_CANDIDATE_REGEX = /\b(?:\d[ -]*?){13,19}\b/

      class << self
        def sanitize(normalized_event, project_id:, config: Sentrace.configuration, secret_base: nil)
          new(config: config, secret_base: secret_base).sanitize(normalized_event, project_id: project_id)
        end
      end

      def initialize(config: Sentrace.configuration, secret_base: nil)
        @config = config
        @secret_base = secret_base
        @redact_terms = (ALWAYS_REDACT_PATTERNS + Array(@config.redact_fields).map { |f| f.to_s.downcase }).uniq
      end

      def sanitize(normalized_event, project_id:)
        base_data = deep_dup(normalized_event.event_data)

        base_data["request"] = sanitize_request(normalized_event.raw_request)
        base_data["user"] = sanitize_user(normalized_event.raw_user, project_id: project_id)
        base_data["tags"] = scrub_hash(base_data["tags"] || {})
        base_data["breadcrumbs"] = scrub_breadcrumbs(base_data["breadcrumbs"] || [])
        base_data["contexts"] = scrub_contexts(base_data["contexts"] || {})
        base_data["message"] = scrub_text(base_data["message"]) if base_data["message"]

        if base_data["exception"].is_a?(Hash)
          exc = base_data["exception"].dup
          exc["value"] = scrub_text(exc["value"]) if exc["value"]
          base_data["exception"] = exc
        end

        if @config.sanitizer
          custom_result = @config.sanitizer.call(deep_dup(base_data))
          unless custom_result.is_a?(Hash)
            raise Error, "Custom Sentrace sanitizer must return a Hash"
          end
          base_data = enforce_post_sanitizer_bounds(custom_result)
        end

        issue_summary_source = base_data.dig("exception", "value") || base_data["message"]
        sanitized_issue_message = issue_summary_source ? issue_summary_source.to_s[0, 1024] : nil

        normalized_event.with(
          issue_message: sanitized_issue_message,
          event_data: base_data,
          raw_user: nil,
          raw_request: nil
        )
      end

      private
        def sanitize_request(raw_request)
          return nil unless raw_request.is_a?(Hash)

          method = raw_request["method"]&.to_s&.strip&.upcase
          method = nil if method && method.empty?
          method = method[0, 16] if method

          url = sanitize_url(raw_request["url"], raw_request["query_string"])
          return nil if url.nil? && method.nil?

          { "url" => url, "method" => method }.compact
        end

        def sanitize_url(raw_url, raw_query_string)
          return nil if raw_url.nil? || raw_url.to_s.strip.empty?

          uri = URI.parse(raw_url.to_s.strip)
          uri.user = nil
          uri.password = nil

          combined_query = [ uri.query, raw_query_string.is_a?(String) ? raw_query_string : nil ]
            .compact
            .reject(&:empty?)
            .join("&")

          if !combined_query.empty?
            scrubbed_pairs = URI.decode_www_form(combined_query).map do |k, v|
              [ k, sensitive_key?(k) ? REDACTED : scrub_text(v) ]
            end
            uri.query = URI.encode_www_form(scrubbed_pairs)
          else
            uri.query = nil
          end

          EventNormalizer.truncate_utf8_bytes(uri.to_s, 1024)
        rescue URI::InvalidURIError, ArgumentError
          # Strip query string and credentials if URL could not be cleanly parsed
          fallback = raw_url.to_s.split("?").first.to_s.sub(%r{//[^/@]+@}, "//")
          EventNormalizer.truncate_utf8_bytes(fallback, 1024)
        end

        def sanitize_user(raw_user, project_id:)
          return nil unless raw_user.is_a?(Hash)

          raw_id = raw_user["id"] || raw_user[:id] ||
            raw_user["username"] || raw_user[:username] ||
            raw_user["email"] || raw_user[:email]
          return nil if raw_id.nil? || raw_id.to_s.strip.empty?

          key_material = "#{effective_secret_base}:sentrace:project:#{project_id}"
          digest = OpenSSL::HMAC.hexdigest("SHA256", key_material, raw_id.to_s)
          { "id_hash" => digest }
        end

        def effective_secret_base
          return @secret_base if @secret_base && !@secret_base.empty?
          return @config.user_hash_secret if @config.user_hash_secret && !@config.user_hash_secret.empty?

          if defined?(Rails) && Rails.application && Rails.application.respond_to?(:secret_key_base) && Rails.application.secret_key_base.present?
            Rails.application.secret_key_base
          else
            "sentrace-default-local-secret"
          end
        end

        def scrub_contexts(contexts_hash)
          return {} unless contexts_hash.is_a?(Hash)

          contexts_hash.each_with_object({}) do |(k, v), acc|
            next if FORBIDDEN_CONTEXT_KEYS.include?(k.to_s.downcase)

            if sensitive_key?(k)
              acc[k.to_s] = REDACTED
            elsif v.is_a?(Hash)
              acc[k.to_s] = scrub_hash(v)
            end
          end
        end

        def scrub_breadcrumbs(crumbs)
          return [] unless crumbs.is_a?(Array)

          crumbs.map do |crumb|
            next unless crumb.is_a?(Hash)

            cleaned = crumb.dup
            cleaned["message"] = scrub_text(cleaned["message"]) if cleaned["message"]
            if cleaned["data"].is_a?(Hash)
              cleaned["data"] = scrub_hash(cleaned["data"])
            end
            cleaned
          end.compact
        end

        def scrub_hash(hash)
          hash.each_with_object({}) do |(k, v), acc|
            key_str = k.to_s
            if FORBIDDEN_CONTEXT_KEYS.include?(key_str.downcase)
              next
            elsif sensitive_key?(key_str)
              acc[key_str] = REDACTED
            else
              acc[key_str] = scrub_value(v)
            end
          end
        end

        def scrub_value(val)
          case val
          when Hash
            scrub_hash(val)
          when Array
            val.map { |item| scrub_value(item) }
          when String
            scrub_text(val)
          else
            val
          end
        end

        def sensitive_key?(key)
          downcased = key.to_s.downcase
          @redact_terms.any? { |term| downcased.include?(term) }
        end

        def scrub_text(text)
          return text unless text.is_a?(String)

          cleaned = text.gsub(BEARER_HEADER_REGEX, "Bearer #{REDACTED}")
          cleaned.gsub(PAN_CANDIDATE_REGEX) do |match|
            digits = match.gsub(/\D/, "")
            luhn_valid?(digits) ? REDACTED : match
          end
        end

        def luhn_valid?(digits)
          return false unless digits.length.between?(13, 19)
          return false if digits.chars.uniq.one?

          sum = 0
          digits.reverse.chars.each_with_index do |ch, idx|
            n = ch.to_i
            if idx.odd?
              n *= 2
              n -= 9 if n > 9
            end
            sum += n
          end
          (sum % 10).zero?
        end

        def enforce_post_sanitizer_bounds(data)
          bounded = data.dup
          if bounded["message"].is_a?(String)
            bounded["message"] = EventNormalizer.truncate_utf8_bytes(bounded["message"], @config.max_message_bytes)
          end

          if bounded["tags"].is_a?(Hash)
            bounded["tags"] = bounded["tags"].first(@config.max_tags).to_h do |k, v|
              [
                EventNormalizer.truncate_utf8_bytes(k.to_s, @config.max_tag_key_bytes),
                v.nil? ? nil : EventNormalizer.truncate_utf8_bytes(v.to_s, @config.max_tag_value_bytes)
              ]
            end
          end

          if bounded["breadcrumbs"].is_a?(Array)
            bounded["breadcrumbs"] = bounded["breadcrumbs"].last(@config.max_breadcrumbs)
          end

          if bounded.dig("exception", "frames").is_a?(Array)
            bounded["exception"] = bounded["exception"].merge(
              "frames" => bounded.dig("exception", "frames").last(@config.max_stack_frames)
            )
          end

          if bounded["contexts"].is_a?(Hash)
            kept = {}
            bounded["contexts"].each do |k, v|
              break if kept.size >= @config.max_context_entries
              candidate = kept.merge(k.to_s => v)
              kept = candidate if JSON.generate(candidate).bytesize <= @config.max_context_bytes
            end
            bounded["contexts"] = kept
          end

          bounded
        end

        def deep_dup(obj)
          case obj
          when Hash
            obj.transform_values { |v| deep_dup(v) }
          when Array
            obj.map { |v| deep_dup(v) }
          when String
            obj.dup
          else
            obj
          end
        end
    end
  end
end
