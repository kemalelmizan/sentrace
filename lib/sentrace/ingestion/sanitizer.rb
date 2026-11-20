require "json"
require "openssl"
require "securerandom"
require "uri"

module Sentrace
  module Ingestion
    class Sanitizer
      REDACTED = "[REDACTED]"
      FALLBACK_SECRET_MUTEX = Mutex.new

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
        passcode
        secret
        secret_key
        secret-key
        secretkey
        token
        authorization
        cookie
        credit_card
        credit-card
        card_number
        card-number
        cvv
        cvc
        api_key
        api-key
        apikey
        private_key
        private-key
        privatekey
        access_key
        access-key
        accesskey
        ip_address
        ip-address
        remote_addr
        remote-addr
        remote_ip
        remote-ip
        client_ip
        client-ip
        x_forwarded_for
        x-forwarded-for
      ].freeze

      SENSITIVE_BOUNDED_KEY_REGEX = /(?:^|[_.-])(?:ssn|otp|totp)(?:$|[_.-])/

      AUTH_SESSION_EXACT_KEYS = %w[
        session
        session_id
        _session_id
        rack.session
        phpsessid
        jsessionid
        connect.sid
      ].freeze

      AUTH_SESSION_KEY_REGEX = /\A_(?:[a-z0-9_]+_)?session\z|(?:^|[_.-])session[_.-]?token\z/

      FORBIDDEN_USER_FIELD_PATTERNS = ALWAYS_REDACT_PATTERNS

      MAX_RETAINED_USER_FIELDS = 16
      MAX_USER_FIELD_BYTES = 256
      MAX_PRE_SCRUB_BYTES = 8192
      MAX_QUERY_PARAMS = 64
      URL_VALUE_KEYS = %w[url from to href location endpoint].freeze

      PEM_HEADER_REGEX = /-----BEGIN [A-Z0-9 ]{0,32}PRIVATE KEY-----/
      PEM_FOOTER_REGEX = /-----END [A-Z0-9 ]{0,32}PRIVATE KEY-----/
      BEARER_HEADER_REGEX = /\bBearer\s+[A-Za-z0-9\-._~+\/]+=*/i
      BASIC_AUTH_HEADER_REGEX = /\bBasic\s+[A-Za-z0-9+\/]{8,}={0,2}/i
      URI_USERINFO_REGEX = %r{\b([a-z][a-z0-9+.-]*://)[^/\s@]*:[^/\s@]*(@)}i
      TRUNCATED_URI_USERINFO_REGEX = %r{\b([a-z][a-z0-9+.-]*://)[^/\s@]{1,128}:[^/\s@]{1,256}\z}i
      RAW_JWT_REGEX = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/
      TRUNCATED_JWT_REGEX = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]*)?\z/
      KNOWN_SECRET_TOKEN_REGEX = /\b(?:snt_mcp_[A-Za-z0-9_-]{16,}|sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{32,}|ya29\.[0-9A-Za-z_-]{20,}|(?:AKIA|ASIA)[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|npm_[A-Za-z0-9]{20,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})\b/
      PAN_CANDIDATE_REGEX = /\b(?:\d[ -]*?){13,19}\b/

      class << self
        def sanitize(normalized_event, project_id:, config: Sentrace.configuration, secret_base: nil)
          new(config: config, secret_base: secret_base).sanitize(normalized_event, project_id: project_id)
        end

        def sanitize_url(raw_url, raw_query_string = nil, config: Sentrace.configuration)
          new(config: config).sanitize_url(raw_url, raw_query_string)
        end

        def redact_inline_secrets(raw_text)
          return raw_text unless raw_text.is_a?(String) && !raw_text.empty?

          cleaned = scrub_pem_blocks(raw_text)
          cleaned = cleaned
            .gsub(BEARER_HEADER_REGEX, "Bearer #{REDACTED}")
            .gsub(BASIC_AUTH_HEADER_REGEX, "Basic #{REDACTED}")
            .gsub(URI_USERINFO_REGEX, "\\1#{REDACTED}\\2")
            .gsub(TRUNCATED_URI_USERINFO_REGEX, "\\1#{REDACTED}")
            .gsub(RAW_JWT_REGEX, REDACTED)
            .gsub(TRUNCATED_JWT_REGEX, REDACTED)
            .gsub(KNOWN_SECRET_TOKEN_REGEX, REDACTED)

          cleaned.gsub(PAN_CANDIDATE_REGEX) do |match|
            digits = match.gsub(/\D/, "")
            luhn_valid?(digits) ? REDACTED : match
          end
        end

        def scrub_pem_blocks(text)
          return text unless text.include?("PRIVATE KEY-----")

          out = +""
          pos = 0
          len = text.length

          while pos < len
            header_match = PEM_HEADER_REGEX.match(text, pos)
            break unless header_match

            out << text[pos...header_match.begin(0)]
            footer_match = PEM_FOOTER_REGEX.match(text, header_match.end(0))
            if footer_match
              out << REDACTED
              pos = footer_match.end(0)
            else
              out << REDACTED
              pos = len
              break
            end
          end

          out << text[pos...len] if pos < len
          out
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

        def ephemeral_fallback_secret
          FALLBACK_SECRET_MUTEX.synchronize do
            @ephemeral_fallback_secret ||= SecureRandom.hex(32)
          end
        end
      end

      def initialize(config: Sentrace.configuration, secret_base: nil)
        @config = config
        @secret_base = secret_base
        @redact_terms = (ALWAYS_REDACT_PATTERNS + Array(@config.redact_fields).map { |f| f.to_s.downcase }).uniq
        @allow_fields = Array(@config.allow_fields)
          .map { |f| f.to_s.strip.downcase }
          .reject(&:empty?)
          .to_h { |f| [ f, true ] }
          .freeze
        @retain_user_fields = Array(@config.retain_user_fields)
          .map { |f| f.to_s.strip }
          .reject(&:empty?)
          .uniq
          .first(MAX_RETAINED_USER_FIELDS)
          .freeze
      end

      def sanitize(normalized_event, project_id:)
        base_data = deep_dup(normalized_event.event_data)
        original_ingestion_source = base_data["ingestion_source"]

        base_data["request"] = sanitize_request(normalized_event.raw_request)
        base_data["user"] = sanitize_user(normalized_event.raw_user, project_id: project_id)
        base_data["tags"] = scrub_hash(base_data["tags"] || {})
        base_data["breadcrumbs"] = scrub_breadcrumbs(base_data["breadcrumbs"] || [])
        base_data["contexts"] = scrub_contexts(base_data["contexts"] || {})
        base_data["message"] = scrub_text(base_data["message"]) if base_data["message"]

        sanitized_exception_type = normalized_event.exception_type ? scrub_single_line(normalized_event.exception_type, 255) : nil
        if base_data["exception"].is_a?(Hash)
          exc = base_data["exception"].dup
          exc["type"] = scrub_single_line(exc["type"], 255) if exc["type"]
          exc["value"] = scrub_text(exc["value"]) if exc["value"]
          if exc["frames"].is_a?(Array)
            exc["frames"] = scrub_frames(exc["frames"])
          end
          sanitized_exception_type ||= exc["type"]
          base_data["exception"] = exc
        end

        if @config.sanitizer
          custom_result = @config.sanitizer.call(deep_dup(base_data))
          unless custom_result.is_a?(Hash)
            raise Error, "Custom Sentrace sanitizer must return a Hash"
          end
          base_data = enforce_post_sanitizer_bounds(custom_result)
        end

        if original_ingestion_source
          base_data["ingestion_source"] = original_ingestion_source
        else
          base_data.delete("ingestion_source")
        end

        issue_summary_source = base_data.dig("exception", "value") || base_data["message"]
        sanitized_issue_message = issue_summary_source ? EventNormalizer.strip_unsafe_characters(issue_summary_source, allow_newlines: true).to_s[0, 1024] : nil

        normalized_event.with(
          environment: scrub_single_line(normalized_event.environment, 64),
          release: scrub_single_line(normalized_event.release, 128),
          platform: scrub_single_line(normalized_event.platform, 32),
          logger: scrub_single_line(normalized_event.logger, 128),
          culprit: scrub_single_line(normalized_event.culprit, 512),
          exception_type: sanitized_exception_type,
          issue_message: sanitized_issue_message,
          event_data: base_data,
          raw_user: nil,
          raw_request: nil
        )
      end

      def sanitize_url(raw_url, raw_query_string = nil)
        return nil if raw_url.nil? || raw_url.to_s.strip.empty?

        bounded_url = EventNormalizer.strip_unsafe_characters(
          EventNormalizer.truncate_utf8_bytes(raw_url, MAX_PRE_SCRUB_BYTES),
          allow_newlines: false
        ).to_s
        return nil if bounded_url.empty?

        bounded_query =
          if raw_query_string.is_a?(String) && !raw_query_string.empty?
            EventNormalizer.strip_unsafe_characters(
              EventNormalizer.truncate_utf8_bytes(raw_query_string, MAX_PRE_SCRUB_BYTES),
              allow_newlines: false
            )
          end

        uri = URI.parse(bounded_url)
        uri.user = nil
        uri.password = nil
        uri.fragment = nil if uri.respond_to?(:fragment=)

        combined_query = [ uri.query, bounded_query ]
          .compact
          .reject(&:empty?)
          .join("&")

        if !combined_query.empty?
          decoded_pairs = URI.decode_www_form(combined_query).first(MAX_QUERY_PARAMS)
          scrubbed_pairs = decoded_pairs.map do |k, v|
            bounded_k = EventNormalizer.truncate_utf8_bytes(k.to_s, 128).to_s
            bounded_v = EventNormalizer.truncate_utf8_bytes(v.to_s, 1024).to_s
            [ bounded_k, sensitive_key?(bounded_k) ? REDACTED : scrub_text(bounded_v) ]
          end
          uri.query = URI.encode_www_form(scrubbed_pairs)
        else
          uri.query = nil
        end

        EventNormalizer.truncate_utf8_bytes(uri.to_s, 1024)
      rescue URI::InvalidURIError, ArgumentError
        # Strip query string, fragment, and credentials if URL could not be cleanly parsed
        fallback = bounded_url.to_s.split(/[?#]/).first.to_s.sub(%r{//[^/@]+@}, "//")
        EventNormalizer.truncate_utf8_bytes(scrub_text(fallback), 1024)
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

        def sanitize_user(raw_user, project_id:)
          return nil unless raw_user.is_a?(Hash)

          raw_id = fetch_user_field(raw_user, "id") ||
            fetch_user_field(raw_user, "user_id") ||
            fetch_user_field(raw_user, "userId") ||
            fetch_user_field(raw_user, "username") ||
            fetch_user_field(raw_user, "email")

          result = {}
          if !raw_id.nil? && !raw_id.to_s.strip.empty?
            bounded_id = EventNormalizer.truncate_utf8_bytes(raw_id.to_s, 1024).to_s
            key_material = "#{effective_secret_base}:sentrace:project:#{project_id}"
            result["id_hash"] = OpenSSL::HMAC.hexdigest("SHA256", key_material, bounded_id)
          end

          @retain_user_fields.each do |field_name|
            next if forbidden_user_field?(field_name)

            raw_val = fetch_user_field(raw_user, field_name)
            sanitized_val = sanitize_user_scalar(raw_val)
            result[field_name] = sanitized_val unless sanitized_val.nil?
          end

          result.empty? ? nil : result
        end

        def fetch_user_field(raw_user, field_name)
          return raw_user[field_name] if raw_user.key?(field_name)

          sym = field_name.to_sym
          raw_user.key?(sym) ? raw_user[sym] : nil
        end

        def forbidden_user_field?(field_name)
          downcased = field_name.to_s.strip.downcase
          return true if downcased.empty? || downcased == "id_hash"
          return true if FORBIDDEN_CONTEXT_KEYS.include?(downcased) || auth_session_key?(downcased)
          return true if SENSITIVE_BOUNDED_KEY_REGEX.match?(downcased)

          FORBIDDEN_USER_FIELD_PATTERNS.any? { |pat| downcased.include?(pat) }
        end

        def sanitize_user_scalar(raw_val)
          case raw_val
          when String
            bounded = EventNormalizer.truncate_utf8_bytes(raw_val, MAX_PRE_SCRUB_BYTES)
            cleaned = EventNormalizer.strip_unsafe_characters(bounded, allow_newlines: false)
            EventNormalizer.truncate_utf8_bytes(scrub_text(cleaned), MAX_USER_FIELD_BYTES)
          when Numeric
            raw_val.to_s.bytesize <= MAX_USER_FIELD_BYTES ? raw_val : EventNormalizer.truncate_utf8_bytes(raw_val.to_s, MAX_USER_FIELD_BYTES)
          when TrueClass, FalseClass
            raw_val
          else
            nil
          end
        end

        def effective_secret_base
          return @secret_base if @secret_base && !@secret_base.empty?
          return @config.user_hash_secret if @config.user_hash_secret && !@config.user_hash_secret.empty?

          if defined?(Rails) && Rails.application && Rails.application.respond_to?(:secret_key_base) && Rails.application.secret_key_base.present?
            Rails.application.secret_key_base
          else
            self.class.ephemeral_fallback_secret
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

        def scrub_frames(frames)
          frames.map do |frame|
            next unless frame.is_a?(Hash)

            cleaned = frame.dup
            if cleaned["filename"].is_a?(String)
              raw_fn = cleaned["filename"]
              cleaned["filename"] =
                if raw_fn.match?(%r{\Ahttps?://}i) || raw_fn.include?("?") || raw_fn.include?("#")
                  sanitize_url(raw_fn) || scrub_single_line(raw_fn, 512)
                else
                  scrub_single_line(raw_fn, 512)
                end
            end
            cleaned["function"] = scrub_single_line(cleaned["function"], 255) if cleaned["function"].is_a?(String)
            cleaned.compact
          end.compact
        end

        def scrub_breadcrumbs(crumbs)
          return [] unless crumbs.is_a?(Array)

          crumbs.map do |crumb|
            next unless crumb.is_a?(Hash)

            cleaned = crumb.dup
            cleaned["timestamp"] = scrub_single_line(cleaned["timestamp"], 64) if cleaned["timestamp"].is_a?(String)
            cleaned["type"] = scrub_single_line(cleaned["type"], 64) if cleaned["type"].is_a?(String)
            cleaned["category"] = scrub_single_line(cleaned["category"], 128) if cleaned["category"].is_a?(String)
            cleaned["level"] = scrub_single_line(cleaned["level"], 32) if cleaned["level"].is_a?(String)
            cleaned["message"] = scrub_text(cleaned["message"]) if cleaned["message"]
            if cleaned["data"].is_a?(Hash)
              cleaned["data"] = scrub_hash(cleaned["data"])
            end
            cleaned.compact
          end.compact
        end

        def scrub_hash(hash)
          hash.each_with_object({}) do |(k, v), acc|
            key_str = k.to_s
            downcased = key_str.strip.downcase
            if FORBIDDEN_CONTEXT_KEYS.include?(downcased) && !@allow_fields.key?(downcased)
              next
            elsif sensitive_key?(key_str)
              acc[key_str] = REDACTED
            elsif URL_VALUE_KEYS.include?(downcased) && v.is_a?(String)
              acc[key_str] = sanitize_url_or_text(v)
            else
              acc[key_str] = scrub_value(v)
            end
          end
        end

        def sanitize_url_or_text(val)
          if val.match?(%r{\A[a-z][a-z0-9+.-]*://}i) || val.start_with?("/") || val.include?("?") || val.include?("#")
            sanitize_url(val) || scrub_text(val)
          else
            scrub_text(val)
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
          downcased = key.to_s.strip.downcase
          return false if @allow_fields.key?(downcased)
          return true if auth_session_key?(downcased)
          return true if SENSITIVE_BOUNDED_KEY_REGEX.match?(downcased)

          @redact_terms.any? { |term| downcased.include?(term) }
        end

        def auth_session_key?(downcased)
          AUTH_SESSION_EXACT_KEYS.include?(downcased) || AUTH_SESSION_KEY_REGEX.match?(downcased)
        end

        def scrub_single_line(text, max_chars)
          return nil if text.nil?

          cleaned = EventNormalizer.strip_unsafe_characters(
            EventNormalizer.truncate_utf8_bytes(text.to_s, MAX_PRE_SCRUB_BYTES),
            allow_newlines: false
          ).to_s.strip
          return nil if cleaned.empty?

          redacted = self.class.redact_inline_secrets(cleaned)
          redacted.length > max_chars ? redacted[0, max_chars] : redacted
        end

        def scrub_text(text)
          return text unless text.is_a?(String)

          bounded = EventNormalizer.truncate_utf8_bytes(text, [ @config.max_message_bytes.to_i, MAX_PRE_SCRUB_BYTES ].max)
          cleaned = EventNormalizer.strip_unsafe_characters(bounded, allow_newlines: true)
          self.class.redact_inline_secrets(cleaned)
        end

        def enforce_post_sanitizer_bounds(data)
          bounded = data.dup
          if bounded["message"].is_a?(String)
            cleaned_msg = EventNormalizer.strip_unsafe_characters(bounded["message"], allow_newlines: true)
            bounded["message"] = EventNormalizer.truncate_utf8_bytes(cleaned_msg, @config.max_message_bytes)
          end

          if bounded["tags"].is_a?(Hash)
            bounded["tags"] = bounded["tags"].first(@config.max_tags).to_h do |k, v|
              clean_k = EventNormalizer.strip_unsafe_characters(k.to_s, allow_newlines: false)
              clean_v = v.nil? ? nil : EventNormalizer.strip_unsafe_characters(v.to_s, allow_newlines: false)
              [
                EventNormalizer.truncate_utf8_bytes(clean_k, @config.max_tag_key_bytes),
                clean_v.nil? ? nil : EventNormalizer.truncate_utf8_bytes(clean_v, @config.max_tag_value_bytes)
              ]
            end
          end

          if bounded["breadcrumbs"].is_a?(Array)
            bounded["breadcrumbs"] = bounded["breadcrumbs"].last(@config.max_breadcrumbs)
          end

          if bounded["user"].is_a?(Hash)
            bounded_user = {}
            bounded["user"].each do |k, v|
              break if bounded_user.size >= (MAX_RETAINED_USER_FIELDS + 1)

              key_str = EventNormalizer.truncate_utf8_bytes(
                EventNormalizer.strip_unsafe_characters(k.to_s, allow_newlines: false),
                64
              )
              next if key_str.nil? || key_str.empty?

              if key_str == "id_hash"
                bounded_user["id_hash"] = EventNormalizer.truncate_utf8_bytes(v.to_s, 64) unless v.nil?
              elsif !forbidden_user_field?(key_str)
                val = sanitize_user_scalar(v)
                bounded_user[key_str] = val unless val.nil?
              end
            end
            bounded["user"] = bounded_user.empty? ? nil : bounded_user
          end

          if bounded["exception"].is_a?(Hash)
            exc = bounded["exception"].dup
            if exc["type"].is_a?(String)
              exc["type"] = scrub_single_line(exc["type"], 255)
            end
            if exc["value"].is_a?(String)
              clean_val = EventNormalizer.strip_unsafe_characters(exc["value"], allow_newlines: true)
              exc["value"] = EventNormalizer.truncate_utf8_bytes(clean_val, @config.max_message_bytes)
            end
            if exc["frames"].is_a?(Array)
              exc["frames"] = scrub_frames(exc["frames"].last(@config.max_stack_frames))
            end
            bounded["exception"] = exc
          end

          if bounded["contexts"].is_a?(Hash)
            kept = {}
            bounded["contexts"].each do |k, v|
              break if kept.size >= @config.max_context_entries

              key_str = EventNormalizer.truncate_utf8_bytes(
                EventNormalizer.strip_unsafe_characters(k.to_s, allow_newlines: false),
                64
              )
              next if key_str.nil? || key_str.empty?
              next if FORBIDDEN_CONTEXT_KEYS.include?(key_str.strip.downcase)
              next unless v.is_a?(Hash)

              candidate = kept.merge(key_str => bound_post_sanitizer_value(v, depth: 0))
              kept = candidate if JSON.generate(candidate).bytesize <= @config.max_context_bytes
            end
            bounded["contexts"] = kept
          end

          bounded
        end

        def bound_post_sanitizer_value(value, depth:)
          return "[TRUNCATED]" if depth > 3

          case value
          when Hash
            value.first(16).to_h do |k, v|
              clean_k = EventNormalizer.strip_unsafe_characters(k.to_s, allow_newlines: false)
              [ EventNormalizer.truncate_utf8_bytes(clean_k, 64), bound_post_sanitizer_value(v, depth: depth + 1) ]
            end
          when Array
            value.first(16).map { |v| bound_post_sanitizer_value(v, depth: depth + 1) }
          when Numeric, TrueClass, FalseClass, NilClass
            value
          else
            clean_str = EventNormalizer.strip_unsafe_characters(value.to_s, allow_newlines: true)
            EventNormalizer.truncate_utf8_bytes(clean_str, 512)
          end
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
