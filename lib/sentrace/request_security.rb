require "ipaddr"
require "uri"

module Sentrace
  module RequestSecurity
    SECURITY_HEADERS = {
      "Cache-Control" => "no-store",
      "X-Content-Type-Options" => "nosniff",
      "X-Frame-Options" => "DENY",
      "Content-Security-Policy" => "default-src 'none'; frame-ancestors 'none'",
      "Referrer-Policy" => "no-referrer"
    }.freeze

    SECURITY_HEADER_NAMES_DOWNCASE = SECURITY_HEADERS.keys.map(&:downcase).freeze

    class << self
      def apply_security_headers!(response)
        SECURITY_HEADERS.each do |header, value|
          response.set_header(header, value)
        end
      end

      def security_header_key?(header_name)
        SECURITY_HEADER_NAMES_DOWNCASE.include?(header_name.to_s.downcase)
      end

      def https_or_loopback?(request)
        return true if request.ssl?
        return false unless loopback_host?(request.host)
        return false unless loopback_ip?(request.remote_ip)

        remote_addr = request.env["REMOTE_ADDR"].to_s.strip
        remote_addr.empty? || loopback_ip?(remote_addr)
      end

      def loopback_host?(raw_host)
        normalized = raw_host.to_s.strip.downcase
        return false if normalized.empty?
        return true if Configuration::LOOPBACK_HOSTS.include?(normalized)

        loopback_ip?(normalized)
      end

      def loopback_ip?(raw_ip)
        addr = parse_ip(raw_ip)
        return false unless addr

        addr.loopback?
      end

      def ip_allowed?(request, allowed_ips)
        entries = Array(allowed_ips).compact
        return true if entries.empty?

        remote_addr = parse_ip(request.remote_ip)
        return false unless remote_addr

        entries.any? do |entry|
          cidr = entry.is_a?(IPAddr) ? normalize_ipaddr(entry) : parse_ip(entry)
          cidr && cidr.include?(remote_addr)
        rescue IPAddr::AddressFamilyError, IPAddr::InvalidAddressError
          false
        end
      end

      def parse_ip(raw_ip)
        cleaned = raw_ip.to_s.strip.delete_prefix("[").delete_suffix("]")
        return nil if cleaned.empty?

        normalize_ipaddr(IPAddr.new(cleaned))
      rescue IPAddr::InvalidAddressError, ArgumentError
        nil
      end

      def forbidden_cross_origin?(request)
        sec_fetch_site = request.headers["Sec-Fetch-Site"].to_s.strip.downcase
        return true if sec_fetch_site == "cross-site"
        return true if sec_fetch_site == "same-site" && unsafe_method?(request)

        raw_origin = request.headers["Origin"].to_s.strip
        return false if raw_origin.empty?
        return true if raw_origin.casecmp("null").zero?

        !same_origin?(request)
      end

      def same_origin?(request)
        verified_same_origin_header?(request)
      end

      def sanitize_single_line(raw_value, max_chars: nil)
        return nil if raw_value.nil?

        cleaned = raw_value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        cleaned.gsub!(/\e(?:\[[0-9;?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\))/, "")
        cleaned.gsub!(/[\x00-\x1F\x7F\u0080-\u009F]/, " ")
        cleaned.gsub!(/[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\u061C\uFEFF\u{E0000}-\u{E007F}]/, "")
        cleaned.strip!
        max_chars ? cleaned[0, max_chars] : cleaned
      end

      def forbidden_cookie_csrf?(request)
        return false unless unsafe_method?(request)
        return false unless request.headers["Authorization"].to_s.strip.empty?
        return false if request.headers["Cookie"].to_s.strip.empty?

        return false if verified_same_origin_header?(request)
        return false if request.media_type.to_s.casecmp("application/json").zero?
        return false unless request.headers["X-CSRF-Token"].to_s.strip.empty?
        return false unless request.headers["X-Requested-With"].to_s.strip.empty?

        true
      end

      def normalize_http_origin(raw_origin)
        stripped = raw_origin.to_s.strip
        return nil if stripped.empty?

        uri = URI.parse(stripped)
        return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
        return nil if uri.userinfo || (uri.path && !uri.path.empty? && uri.path != "/") || uri.query || uri.fragment

        default_port = uri.scheme.casecmp("https").zero? ? 443 : 80
        port_part = uri.port && uri.port != default_port ? ":#{uri.port}" : ""
        "#{uri.scheme.downcase}://#{uri.host.downcase}#{port_part}"
      rescue URI::InvalidURIError
        nil
      end

      def scalar_param(params, key)
        return nil unless params.key?(key)

        value = params[key]
        if (defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)) ||
           value.is_a?(Hash) ||
           value.is_a?(Array)
          raise McpInvalidParamsError, "#{key} must be a scalar value"
        end

        value
      end

      private
        def normalize_ipaddr(addr)
          addr.ipv4_mapped? ? addr.native : addr
        end

        def unsafe_method?(request)
          !request.get? && !request.head? && !request.options?
        end

        def verified_same_origin_header?(request)
          raw_origin = request.headers["Origin"].to_s.strip
          return false if raw_origin.empty? || raw_origin.casecmp("null").zero?

          request_origin = normalize_http_origin(raw_origin)
          expected_origin = normalize_http_origin(request.base_url.to_s)
          !request_origin.nil? && request_origin == expected_origin
        end
    end
  end
end
