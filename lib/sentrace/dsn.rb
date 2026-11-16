require "uri"

module Sentrace
  class Dsn
    SUPPORTED_SCHEMES = %w[http https].freeze

    attr_reader :scheme, :public_key, :secret_key, :host, :port, :path_prefix, :project_id

    class << self
      def parse(raw_dsn)
        if raw_dsn.nil? || raw_dsn.to_s.strip.empty?
          raise InvalidDsnError, "DSN cannot be blank"
        end

        uri = URI.parse(raw_dsn.to_s.strip)
        validate_uri!(uri)

        segments = uri.path.to_s.split("/").reject(&:empty?)
        if segments.empty?
          raise InvalidDsnError, "DSN must include a trailing project identifier"
        end

        project_id = segments.pop
        prefix = segments.empty? ? "" : "/#{segments.join("/")}"

        new(
          scheme: uri.scheme.downcase,
          public_key: URI.decode_www_form_component(uri.user),
          secret_key: uri.password ? URI.decode_www_form_component(uri.password) : nil,
          host: uri.host,
          port: uri.port,
          path_prefix: prefix,
          project_id: project_id
        )
      rescue URI::InvalidURIError
        raise InvalidDsnError, "Malformed DSN URI"
      end

      def build(base_url:, public_key:, project_id:, secret_key: nil)
        if base_url.nil? || base_url.to_s.strip.empty?
          raise InvalidDsnError, "base_url cannot be blank"
        end

        uri = URI.parse(base_url.to_s.strip)
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && SUPPORTED_SCHEMES.include?(uri.scheme&.downcase)
          raise InvalidDsnError, "base_url must be a valid HTTP or HTTPS URL"
        end

        prefix_segments = uri.path.to_s.split("/").reject(&:empty?)
        prefix = prefix_segments.empty? ? "" : "/#{prefix_segments.join("/")}"

        new(
          scheme: uri.scheme.downcase,
          public_key: public_key.to_s.strip,
          secret_key: secret_key&.to_s,
          host: uri.host,
          port: uri.port,
          path_prefix: prefix,
          project_id: project_id.to_s.strip
        )
      rescue URI::InvalidURIError
        raise InvalidDsnError, "Invalid base_url for DSN"
      end

      private
        def validate_uri!(uri)
          unless SUPPORTED_SCHEMES.include?(uri.scheme&.downcase)
            raise InvalidDsnError, "DSN scheme must be http or https"
          end

          if uri.host.nil? || uri.host.empty?
            raise InvalidDsnError, "DSN must include a host"
          end

          if uri.user.nil? || uri.user.empty?
            raise InvalidDsnError, "DSN must include a public key in userinfo"
          end
        end
    end

    def initialize(scheme:, public_key:, host:, port:, path_prefix:, project_id:, secret_key: nil)
      if public_key.nil? || public_key.empty?
        raise InvalidDsnError, "DSN public_key cannot be blank"
      end

      if project_id.nil? || project_id.empty?
        raise InvalidDsnError, "DSN project_id cannot be blank"
      end

      @scheme = scheme
      @public_key = public_key
      @secret_key = (secret_key && !secret_key.empty?) ? secret_key : nil
      @host = host
      @port = port
      @path_prefix = path_prefix.to_s
      @project_id = project_id
      freeze
    end

    def to_s
      userinfo = secret_key ? "#{public_key}:#{secret_key}" : public_key
      "#{scheme}://#{userinfo}@#{authority_host}#{path_prefix}/#{project_id}"
    end

    def without_secret
      return self if secret_key.nil?

      self.class.new(
        scheme: scheme,
        public_key: public_key,
        secret_key: nil,
        host: host,
        port: port,
        path_prefix: path_prefix,
        project_id: project_id
      )
    end

    def envelope_endpoint
      "#{scheme}://#{authority_host}#{path_prefix}/api/#{project_id}/envelope/"
    end

    def inspect
      masked = secret_key ? "[REDACTED]" : "nil"
      "#<#{self.class.name} scheme=#{scheme.inspect} host=#{host.inspect} port=#{port.inspect} " \
        "path_prefix=#{path_prefix.inspect} project_id=#{project_id.inspect} " \
        "public_key=#{public_key.inspect} secret_key=#{masked}>"
    end

    private
      def authority_host
        default_port = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        formatted_host = host.include?(":") && !host.start_with?("[") ? "[#{host}]" : host
        (port && !default_port) ? "#{formatted_host}:#{port}" : formatted_host
      end
  end
end
