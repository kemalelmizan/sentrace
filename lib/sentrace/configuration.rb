require "active_support/core_ext/numeric/bytes"
require "active_support/core_ext/numeric/time"
require "ipaddr"
require "uri"

module Sentrace
  class Configuration
    DEFAULT_REDACT_FIELDS = %w[
      password
      token
      authorization
      cookie
      credit_card
    ].freeze

    DEFAULT_EXCLUDED_EXCEPTIONS = %w[
      AbstractController::ActionNotFound
      ActionController::BadRequest
      ActionController::InvalidAuthenticityToken
      ActionController::InvalidCrossOriginRequest
      ActionController::Live::ClientDisconnected
      ActionController::MethodNotAllowed
      ActionController::NotImplemented
      ActionController::ParameterMissing
      ActionController::RoutingError
      ActionController::UnknownFormat
      ActionController::UnknownHttpMethod
      ActionDispatch::Http::MimeNegotiation::InvalidType
      ActionDispatch::Http::Parameters::ParseError
      ActionDispatch::RemoteIp::IpSpoofAttackError
      ActiveRecord::RecordNotFound
      CGI::Session::CookieStore::TamperedWithCookie
      Mime::Type::InvalidMimeType
      Rack::Multipart::BoundaryTooLongError
      Rack::Multipart::EmptyContentError
      Rack::Multipart::Error
      Rack::Multipart::MultipartPartLimitError
      Rack::Multipart::MultipartTotalPartLimitError
      Rack::QueryParser::InvalidParameterError
      Rack::QueryParser::ParameterTypeError
    ].freeze

    SUPPORTED_BREADCRUMBS_LOGGERS = %i[active_support_logger http_logger].freeze
    SUPPORTED_CAPTURE_DISPATCH_MODES = %i[async inline].freeze

    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze
    DEFAULT_MAX_EVENTS_PER_ENVELOPE = 10
    DEFAULT_MAX_ENVELOPE_ITEMS = 50
    DEFAULT_INGESTION_RATE_LIMIT_PER_MINUTE = 300
    DEFAULT_INGESTION_PROJECT_RATE_LIMIT_PER_MINUTE = 3_000
    DEFAULT_IN_PROCESS_RATE_LIMIT_PER_MINUTE = 1_000
    DEFAULT_MAX_FUTURE_CLOCK_SKEW = 0.seconds

    POSITIVE_NUMERIC_ATTRIBUTES = %i[
      retention_period
      orphan_issue_retention_period
      max_envelope_size
      max_message_bytes
      max_stack_frames
      max_breadcrumbs
      max_breadcrumbs_bytes
      max_tags
      max_tag_key_bytes
      max_tag_value_bytes
      max_context_entries
      max_context_bytes
      max_event_data_bytes
      remote_timeout
      remote_ping_timeout
    ].freeze

    NON_NEGATIVE_NUMERIC_ATTRIBUTES = %i[
      max_future_clock_skew
    ].freeze

    POSITIVE_INTEGER_ATTRIBUTES = %i[
      retention_batch_size
      max_events_per_envelope
      max_envelope_items
    ].freeze

    EnvironmentDefinition = Data.define(:name, :transport, :url, :token, :timeout, :read_only) do
      def initialize(name:, transport:, url: nil, token: nil, timeout: nil, read_only: false)
        super
      end

      def inspect
        masked_token = token ? "[REDACTED]" : "nil"
        "#<#{self.class.name} name=#{name.inspect} transport=#{transport.inspect} url=#{url.inspect} token=#{masked_token} timeout=#{timeout.inspect} read_only=#{read_only.inspect}>"
      end
      alias_method :to_s, :inspect
    end

    attr_accessor :enabled,
      :deployment_environment,
      :project_slug,
      :project_id,
      :sample_rate,
      :excluded_exceptions,
      :before_send,
      :breadcrumbs_logger,
      :async_queue_size,
      :capture_dispatch,
      :frontend_dsn,
      :public_base_url,
      :allow_request_base_url_fallback,
      :release,
      :cors_allowed_origins,
      :retention_period,
      :orphan_issue_retention_period,
      :retention_batch_size,
      :max_future_clock_skew,
      :max_envelope_size,
      :max_events_per_envelope,
      :max_envelope_items,
      :max_message_bytes,
      :max_stack_frames,
      :max_breadcrumbs,
      :max_breadcrumbs_bytes,
      :max_tags,
      :max_tag_key_bytes,
      :max_tag_value_bytes,
      :max_context_entries,
      :max_context_bytes,
      :max_event_data_bytes,
      :redact_fields,
      :allow_fields,
      :retain_user_fields,
      :sanitizer,
      :internal_authenticator,
      :trust_forwarded_headers,
      :mcp_allowed_ips,
      :internal_allowed_ips,
      :mcp_rate_limit_per_minute,
      :mcp_auth_failure_limit_per_minute,
      :ingestion_rate_limit_per_minute,
      :ingestion_project_rate_limit_per_minute,
      :in_process_rate_limit_per_minute,
      :user_hash_secret,
      :remote_timeout,
      :remote_ping_timeout

    attr_writer :capture_unhandled_exceptions
    attr_reader :environments

    def initialize
      @enabled = true
      @deployment_environment = default_deployment_environment
      @project_slug = nil
      @project_id = nil
      @capture_unhandled_exceptions = nil
      @sample_rate = 1.0
      @excluded_exceptions = DEFAULT_EXCLUDED_EXCEPTIONS.dup
      @before_send = nil
      @breadcrumbs_logger = []
      @async_queue_size = 256
      @capture_dispatch = :async
      @frontend_dsn = nil
      @public_base_url = nil
      @allow_request_base_url_fallback = true
      @release = ENV["APP_RELEASE"]
      @cors_allowed_origins = []
      @retention_period = 30.days
      @orphan_issue_retention_period = 7.days
      @retention_batch_size = 1_000
      @max_future_clock_skew = DEFAULT_MAX_FUTURE_CLOCK_SKEW
      @max_envelope_size = 1.megabyte
      @max_events_per_envelope = DEFAULT_MAX_EVENTS_PER_ENVELOPE
      @max_envelope_items = DEFAULT_MAX_ENVELOPE_ITEMS
      @max_message_bytes = 4.kilobytes
      @max_stack_frames = 50
      @max_breadcrumbs = 20
      @max_breadcrumbs_bytes = 24.kilobytes
      @max_tags = 32
      @max_tag_key_bytes = 64
      @max_tag_value_bytes = 256
      @max_context_entries = 16
      @max_context_bytes = 8.kilobytes
      @max_event_data_bytes = 32.kilobytes
      @redact_fields = DEFAULT_REDACT_FIELDS.dup
      @allow_fields = []
      @retain_user_fields = []
      @sanitizer = nil
      @internal_authenticator = nil
      @trust_forwarded_headers = true
      @mcp_allowed_ips = []
      @internal_allowed_ips = []
      @mcp_rate_limit_per_minute = 120
      @mcp_auth_failure_limit_per_minute = 20
      @ingestion_rate_limit_per_minute = DEFAULT_INGESTION_RATE_LIMIT_PER_MINUTE
      @ingestion_project_rate_limit_per_minute = DEFAULT_INGESTION_PROJECT_RATE_LIMIT_PER_MINUTE
      @in_process_rate_limit_per_minute = DEFAULT_IN_PROCESS_RATE_LIMIT_PER_MINUTE
      @user_hash_secret = nil
      @remote_timeout = 5.0
      @remote_ping_timeout = 2.5
      self.environments = { local: { transport: :local } }
    end

    def initialize_copy(other)
      super
      @excluded_exceptions = other.excluded_exceptions.dup
      @breadcrumbs_logger = other.breadcrumbs_logger.dup
      @cors_allowed_origins = other.cors_allowed_origins.is_a?(Array) ? other.cors_allowed_origins.map(&:dup) : other.cors_allowed_origins.dup
      @redact_fields = other.redact_fields.dup
      @allow_fields = other.allow_fields.dup
      @retain_user_fields = other.retain_user_fields.dup
      @mcp_allowed_ips = other.mcp_allowed_ips.is_a?(Array) ? other.mcp_allowed_ips.map(&:dup) : other.mcp_allowed_ips.dup
      @internal_allowed_ips = other.internal_allowed_ips.is_a?(Array) ? other.internal_allowed_ips.map(&:dup) : other.internal_allowed_ips.dup
      @environments = other.environments.dup
    end

    def environments=(raw_environments)
      unless raw_environments.is_a?(Hash) && raw_environments.any?
        raise ConfigurationError, "environments must be a non-empty Hash"
      end

      @environments = raw_environments.each_with_object({}) do |(key, value), acc|
        unless value.is_a?(Hash)
          raise ConfigurationError, "environment #{key.inspect} definition must be a Hash"
        end

        env_name = key.to_sym
        opts = value.transform_keys(&:to_sym)
        transport = opts[:transport]&.to_sym

        acc[env_name] = EnvironmentDefinition.new(
          name: env_name,
          transport: transport,
          url: opts[:url],
          token: opts[:token],
          timeout: opts.fetch(:timeout, @remote_timeout),
          read_only: opts.fetch(:read_only, false)
        )
      end
    end

    def validate!
      POSITIVE_NUMERIC_ATTRIBUTES.each do |attr|
        val = public_send(attr)
        valid = val.is_a?(Numeric) &&
          (!val.respond_to?(:nan?) || !val.nan?) &&
          (!val.respond_to?(:infinite?) || !val.infinite?) &&
          val.positive?
        unless valid
          raise ConfigurationError, "#{attr} must be a positive number (got #{val.inspect})"
        end
      end

      NON_NEGATIVE_NUMERIC_ATTRIBUTES.each do |attr|
        val = public_send(attr)
        valid = val.is_a?(Numeric) &&
          (!val.respond_to?(:nan?) || !val.nan?) &&
          (!val.respond_to?(:infinite?) || !val.infinite?) &&
          val >= 0
        unless valid
          raise ConfigurationError, "#{attr} must be a non-negative number (got #{val.inspect})"
        end
      end

      unless redact_fields.is_a?(Array) && redact_fields.all? { |f| f.is_a?(String) || f.is_a?(Symbol) }
        raise ConfigurationError, "redact_fields must be an Array of field names"
      end

      unless allow_fields.is_a?(Array) && allow_fields.all? { |f| f.is_a?(String) || f.is_a?(Symbol) }
        raise ConfigurationError, "allow_fields must be an Array of field names"
      end

      unless retain_user_fields.is_a?(Array) && retain_user_fields.all? { |f| f.is_a?(String) || f.is_a?(Symbol) }
        raise ConfigurationError, "retain_user_fields must be an Array of field names"
      end

      POSITIVE_INTEGER_ATTRIBUTES.each do |attr|
        val = public_send(attr)
        unless val.is_a?(Integer) && val.positive?
          raise ConfigurationError, "#{attr} must be a positive Integer (got #{val.inspect})"
        end
      end

      if !sanitizer.nil? && !sanitizer.respond_to?(:call)
        raise ConfigurationError, "sanitizer must respond to #call"
      end

      if !internal_authenticator.nil? && !internal_authenticator.respond_to?(:call)
        raise ConfigurationError, "internal_authenticator must respond to #call"
      end

      if deployment_environment.nil? || deployment_environment.to_s.strip.empty?
        raise ConfigurationError, "deployment_environment must be a non-empty String or Symbol"
      end

      validate_ip_allowlist!(:mcp_allowed_ips, mcp_allowed_ips)
      validate_ip_allowlist!(:internal_allowed_ips, internal_allowed_ips)
      validate_optional_positive_integer!(:mcp_rate_limit_per_minute, mcp_rate_limit_per_minute)
      validate_optional_positive_integer!(:mcp_auth_failure_limit_per_minute, mcp_auth_failure_limit_per_minute)
      validate_optional_positive_integer!(:ingestion_rate_limit_per_minute, ingestion_rate_limit_per_minute)
      validate_optional_positive_integer!(:ingestion_project_rate_limit_per_minute, ingestion_project_rate_limit_per_minute)
      validate_optional_positive_integer!(:in_process_rate_limit_per_minute, in_process_rate_limit_per_minute)
      validate_boolean!(:allow_request_base_url_fallback, allow_request_base_url_fallback)
      validate_boolean!(:trust_forwarded_headers, trust_forwarded_headers)

      validate_capture_client_settings!
      validate_frontend_settings!
      validate_environments!
      true
    end

    def capture_unhandled_exceptions
      return @capture_unhandled_exceptions unless @capture_unhandled_exceptions.nil?

      target_project_configured?
    end

    def target_project_configured?
      has_id = !project_id.nil? && !project_id.to_s.strip.empty?
      has_slug = !project_slug.nil? && !project_slug.to_s.strip.empty?
      has_id || has_slug
    end

    def cors_origin_header_for(origin)
      raw_origin = origin.to_s.strip
      return nil if raw_origin.empty?

      origins = cors_allowed_origins == "*" ? [ "*" ] : Array(cors_allowed_origins)
      return "*" if origins.any? { |entry| entry.to_s.strip == "*" }

      normalized_request_origin = normalize_origin(raw_origin)
      return nil unless normalized_request_origin

      matched = origins.any? { |entry| normalize_origin(entry.to_s) == normalized_request_origin }
      matched ? normalized_request_origin : nil
    end

    def inspect
      masked_secret = user_hash_secret ? "[REDACTED]" : "nil"
      masked_dsn = safe_inspect_dsn(frontend_dsn)
      "#<#{self.class.name} enabled=#{enabled.inspect} deployment_environment=#{deployment_environment.inspect} " \
        "frontend_dsn=#{masked_dsn.inspect} cors_allowed_origins=#{cors_allowed_origins.inspect} " \
        "retention_period=#{retention_period.inspect} " \
        "max_envelope_size=#{max_envelope_size.inspect} max_stack_frames=#{max_stack_frames.inspect} " \
        "max_breadcrumbs=#{max_breadcrumbs.inspect} max_tags=#{max_tags.inspect} " \
        "user_hash_secret=#{masked_secret} environments=#{environments.inspect}>"
    end

    private
      def validate_ip_allowlist!(attr_name, raw_list)
        return if raw_list.nil?

        unless raw_list.is_a?(Array)
          raise ConfigurationError, "#{attr_name} must be an Array of IP/CIDR strings or nil"
        end

        raw_list.each do |entry|
          next if entry.is_a?(IPAddr)

          unless entry.is_a?(String) && !entry.strip.empty?
            raise ConfigurationError, "#{attr_name} entries must be non-empty IP/CIDR strings (got #{entry.inspect})"
          end

          begin
            IPAddr.new(entry.strip)
          rescue IPAddr::InvalidAddressError, ArgumentError
            raise ConfigurationError, "#{attr_name} entry #{entry.inspect} is not a valid IP or CIDR"
          end
        end
      end

      def validate_optional_positive_integer!(attr_name, val)
        return if val.nil?
        return if val.is_a?(Integer) && val.positive?

        raise ConfigurationError, "#{attr_name} must be a positive Integer or nil (got #{val.inspect})"
      end

      def validate_boolean!(attr_name, val)
        return if val == true || val == false

        raise ConfigurationError, "#{attr_name} must be true or false (got #{val.inspect})"
      end

      def validate_capture_client_settings!
        unless project_slug.nil? || project_slug.is_a?(String) || project_slug.is_a?(Symbol)
          raise ConfigurationError, "project_slug must be a String, Symbol, or nil"
        end

        unless valid_project_id?(project_id)
          raise ConfigurationError, "project_id must be a positive Integer or nil (got #{project_id.inspect})"
        end

        unless @capture_unhandled_exceptions.nil? || @capture_unhandled_exceptions == true || @capture_unhandled_exceptions == false
          raise ConfigurationError, "capture_unhandled_exceptions must be true, false, or nil"
        end

        unless sample_rate.is_a?(Numeric) && (!sample_rate.respond_to?(:nan?) || !sample_rate.nan?) && sample_rate >= 0.0 && sample_rate <= 1.0
          raise ConfigurationError, "sample_rate must be a Numeric between 0.0 and 1.0 (got #{sample_rate.inspect})"
        end

        unless excluded_exceptions.is_a?(Array) && excluded_exceptions.all? { |e| e.is_a?(String) || e.is_a?(Symbol) || e.is_a?(Module) }
          raise ConfigurationError, "excluded_exceptions must be an Array of exception class names or Modules"
        end

        if !before_send.nil? && !before_send.respond_to?(:call)
          raise ConfigurationError, "before_send must respond to #call"
        end

        unless breadcrumbs_logger.is_a?(Array) && breadcrumbs_logger.all? { |l| (l.is_a?(String) || l.is_a?(Symbol)) && SUPPORTED_BREADCRUMBS_LOGGERS.include?(l.to_sym) }
          raise ConfigurationError,
            "breadcrumbs_logger must be an Array containing only #{SUPPORTED_BREADCRUMBS_LOGGERS.inspect}"
        end

        unless async_queue_size.is_a?(Integer) && async_queue_size.positive?
          raise ConfigurationError, "async_queue_size must be a positive Integer (got #{async_queue_size.inspect})"
        end

        unless (capture_dispatch.is_a?(Symbol) || capture_dispatch.is_a?(String)) && SUPPORTED_CAPTURE_DISPATCH_MODES.include?(capture_dispatch.to_sym)
          raise ConfigurationError,
            "capture_dispatch must be :async or :inline (got #{capture_dispatch.inspect})"
        end

        @capture_dispatch = capture_dispatch.to_sym
      end

      def valid_project_id?(val)
        return true if val.nil?
        return val.positive? if val.is_a?(Integer)
        return true if val.is_a?(String) && (val.strip.empty? || val.strip.match?(/\A[1-9]\d*\z/))

        false
      end

      def validate_frontend_settings!
        unless frontend_dsn.nil? || frontend_dsn.to_s.strip.empty?
          Dsn.parse(frontend_dsn.to_s)
        end

        validate_public_base_url!

        unless release.nil? || release.is_a?(String) || release.is_a?(Symbol)
          raise ConfigurationError, "release must be a String, Symbol, or nil"
        end

        validate_cors_allowed_origins!
      rescue InvalidDsnError => e
        raise ConfigurationError, "frontend_dsn is invalid: #{e.message}"
      end

      def validate_public_base_url!
        return if public_base_url.nil?

        unless public_base_url.is_a?(String)
          raise ConfigurationError, "public_base_url must be a String or nil"
        end

        stripped = public_base_url.strip
        return if stripped.empty?

        uri = URI.parse(stripped)
        if !uri.is_a?(URI::HTTP) || uri.host.nil? || uri.host.empty? || uri.userinfo || uri.query || uri.fragment
          raise ConfigurationError, "public_base_url must be a valid HTTP(S) base URL without credentials, query, or fragment"
        end
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "public_base_url is invalid: #{e.message}"
      end

      def validate_cors_allowed_origins!
        if cors_allowed_origins == "*"
          return
        end

        unless cors_allowed_origins.is_a?(Array) && cors_allowed_origins.all? { |o| o.is_a?(String) }
          raise ConfigurationError, "cors_allowed_origins must be '*' or an Array of origin Strings"
        end

        cors_allowed_origins.each do |entry|
          stripped = entry.strip
          next if stripped == "*"

          if normalize_origin(stripped).nil?
            raise ConfigurationError, "cors_allowed_origins entry #{entry.inspect} must be '*' or a valid http(s) origin"
          end
        end
      end

      def normalize_origin(raw)
        uri = URI.parse(raw.strip)
        return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
        return nil if uri.userinfo || (uri.path && !uri.path.empty? && uri.path != "/") || uri.query || uri.fragment

        default_port = uri.scheme == "https" ? 443 : 80
        port_part = uri.port && uri.port != default_port ? ":#{uri.port}" : ""
        "#{uri.scheme.downcase}://#{uri.host.downcase}#{port_part}"
      rescue URI::InvalidURIError
        nil
      end

      def safe_inspect_dsn(raw_dsn)
        return nil if raw_dsn.nil?

        Dsn.parse(raw_dsn.to_s).without_secret.to_s
      rescue InvalidDsnError
        "[INVALID_DSN]"
      end
      def default_deployment_environment
        if defined?(Rails) && Rails.respond_to?(:env) && !Rails.env.to_s.empty?
          Rails.env.to_s
        else
          "local"
        end
      end
      def validate_environments!
        unless environments.is_a?(Hash) && environments.any?
          raise ConfigurationError, "environments must be a non-empty Hash"
        end

        environments.each_value do |env_def|
          unless env_def.read_only == true || env_def.read_only == false
            raise ConfigurationError,
              "environment #{env_def.name.inspect} read_only must be true or false (got #{env_def.read_only.inspect})"
          end

          case env_def.transport
          when :local
            next
          when :http
            validate_http_environment!(env_def)
          else
            raise ConfigurationError,
              "environment #{env_def.name.inspect} has unsupported transport #{env_def.transport.inspect} (expected :local or :http)"
          end
        end
      end

      def validate_http_environment!(env_def)
        unless env_def.timeout.is_a?(Numeric) && env_def.timeout.positive?
          raise ConfigurationError, "environment #{env_def.name.inspect} timeout must be a positive number"
        end

        if !env_def.token.nil? && !env_def.token.is_a?(String)
          raise ConfigurationError, "environment #{env_def.name.inspect} token must be a String or nil"
        end

        raw_token = env_def.token.to_s.strip
        if !raw_token.empty? && raw_token.match?(/[\s\x00-\x1F\x7F]/)
          raise ConfigurationError,
            "environment #{env_def.name.inspect} token must not contain whitespace or control characters"
        end

        raw_url = env_def.url.to_s.strip
        return if raw_url.empty?

        uri = URI.parse(raw_url)
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
          raise ConfigurationError, "environment #{env_def.name.inspect} url #{env_def.url.inspect} is invalid"
        end

        if uri.userinfo || uri.fragment
          raise ConfigurationError,
            "environment #{env_def.name.inspect} url must not contain embedded credentials or fragments"
        end

        if uri.scheme != "https" && !RequestSecurity.loopback_host?(uri.host)
          raise ConfigurationError,
            "environment #{env_def.name.inspect} requires HTTPS for non-local host #{uri.host.inspect}"
        end
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "environment #{env_def.name.inspect} url is invalid: #{e.message}"
      end
  end
end
