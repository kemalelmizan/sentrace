require "active_support/core_ext/numeric/bytes"
require "active_support/core_ext/numeric/time"
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

    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

    POSITIVE_NUMERIC_ATTRIBUTES = %i[
      retention_period
      orphan_issue_retention_period
      max_envelope_size
      max_message_bytes
      max_stack_frames
      max_breadcrumbs
      max_tags
      max_tag_key_bytes
      max_tag_value_bytes
      max_context_entries
      max_context_bytes
      remote_timeout
    ].freeze

    EnvironmentDefinition = Data.define(:name, :transport, :url, :token, :timeout) do
      def inspect
        masked_token = token ? "[REDACTED]" : "nil"
        "#<#{self.class.name} name=#{name.inspect} transport=#{transport.inspect} url=#{url.inspect} token=#{masked_token} timeout=#{timeout.inspect}>"
      end
      alias_method :to_s, :inspect
    end

    attr_accessor :enabled,
      :deployment_environment,
      :retention_period,
      :orphan_issue_retention_period,
      :max_envelope_size,
      :max_message_bytes,
      :max_stack_frames,
      :max_breadcrumbs,
      :max_tags,
      :max_tag_key_bytes,
      :max_tag_value_bytes,
      :max_context_entries,
      :max_context_bytes,
      :redact_fields,
      :sanitizer,
      :user_hash_secret,
      :remote_timeout

    attr_reader :environments

    def initialize
      @enabled = true
      @deployment_environment = default_deployment_environment
      @retention_period = 30.days
      @orphan_issue_retention_period = 7.days
      @max_envelope_size = 1.megabyte
      @max_message_bytes = 4.kilobytes
      @max_stack_frames = 50
      @max_breadcrumbs = 20
      @max_tags = 32
      @max_tag_key_bytes = 64
      @max_tag_value_bytes = 256
      @max_context_entries = 16
      @max_context_bytes = 8.kilobytes
      @redact_fields = DEFAULT_REDACT_FIELDS.dup
      @sanitizer = nil
      @user_hash_secret = nil
      @remote_timeout = 5.0
      self.environments = { local: { transport: :local } }
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
          timeout: opts.fetch(:timeout, @remote_timeout)
        )
      end
    end

    def validate!
      POSITIVE_NUMERIC_ATTRIBUTES.each do |attr|
        val = public_send(attr)
        unless val.is_a?(Numeric) && val.positive?
          raise ConfigurationError, "#{attr} must be a positive number (got #{val.inspect})"
        end
      end

      unless redact_fields.is_a?(Array) && redact_fields.all? { |f| f.is_a?(String) || f.is_a?(Symbol) }
        raise ConfigurationError, "redact_fields must be an Array of field names"
      end

      if !sanitizer.nil? && !sanitizer.respond_to?(:call)
        raise ConfigurationError, "sanitizer must respond to #call"
      end

      if deployment_environment.nil? || deployment_environment.to_s.strip.empty?
        raise ConfigurationError, "deployment_environment must be a non-empty String or Symbol"
      end

      validate_environments!
      true
    end

    def inspect
      masked_secret = user_hash_secret ? "[REDACTED]" : "nil"
      "#<#{self.class.name} enabled=#{enabled.inspect} deployment_environment=#{deployment_environment.inspect} " \
        "retention_period=#{retention_period.inspect} " \
        "max_envelope_size=#{max_envelope_size.inspect} max_stack_frames=#{max_stack_frames.inspect} " \
        "max_breadcrumbs=#{max_breadcrumbs.inspect} max_tags=#{max_tags.inspect} " \
        "user_hash_secret=#{masked_secret} environments=#{environments.inspect}>"
    end

    private
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

        if env_def.url.nil? || env_def.url.to_s.strip.empty?
          raise ConfigurationError, "environment #{env_def.name.inspect} requires a url for :http transport"
        end

        uri = URI.parse(env_def.url.to_s)
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
          raise ConfigurationError, "environment #{env_def.name.inspect} url #{env_def.url.inspect} is invalid"
        end

        if uri.scheme != "https" && !LOOPBACK_HOSTS.include?(uri.host.downcase)
          raise ConfigurationError,
            "environment #{env_def.name.inspect} requires HTTPS for non-local host #{uri.host.inspect}"
        end
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "environment #{env_def.name.inspect} url is invalid: #{e.message}"
      end
  end
end
