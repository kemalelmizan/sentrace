require "mcp"
require "rack"

module Sentrace
  class McpController < ApplicationController
    MAX_MCP_REQUEST_BYTES = 1.megabyte

    # Prevent ActionController::Instrumentation#process_action from triggering Rails'
    # unbounded body parser; StreamableHTTPTransport enforces MAX_MCP_REQUEST_BYTES directly.
    def process_action(*)
      request.set_header("action_dispatch.request.request_parameters", {})
      super
    end

    def handle
      config = Sentrace.configuration

      unless https_or_loopback?
        return render json: { error: "HTTPS is required for non-local MCP endpoints" }, status: :forbidden
      end

      if RequestSecurity.forbidden_cross_origin?(request)
        return render json: { error: "Cross-origin MCP requests are forbidden" }, status: :forbidden
      end

      unless RequestSecurity.ip_allowed?(request, config.mcp_allowed_ips)
        return render json: { error: "IP address not allowed" }, status: :forbidden
      end

      client_ip = rate_limit_identifier
      raw_bearer = extract_bearer_token
      known_verified = raw_bearer && McpToken.recently_verified_raw_token?(raw_bearer)

      unless known_verified
        rate_result = RateLimiter.check!(
          bucket: "mcp",
          identifier: "ip:#{client_ip}",
          limit: config.mcp_rate_limit_per_minute
        )
        unless rate_result[:allowed]
          return render_rate_limited(rate_result[:retry_after])
        end

        if config.mcp_auth_failure_limit_per_minute
          auth_precheck = RateLimiter.check!(
            bucket: "mcp_auth_fail",
            identifier: client_ip,
            limit: config.mcp_auth_failure_limit_per_minute,
            increment: false
          )
          if auth_precheck[:count] >= config.mcp_auth_failure_limit_per_minute
            return render_rate_limited(auth_precheck[:retry_after])
          end
        end
      end

      token_record = raw_bearer ? McpToken.authenticate(raw_bearer) : nil
      unless token_record
        if known_verified
          ip_rate = RateLimiter.check!(
            bucket: "mcp",
            identifier: "ip:#{client_ip}",
            limit: config.mcp_rate_limit_per_minute
          )
          return render_rate_limited(ip_rate[:retry_after]) unless ip_rate[:allowed]
        end

        if config.mcp_auth_failure_limit_per_minute
          fail_result = RateLimiter.check!(
            bucket: "mcp_auth_fail",
            identifier: client_ip,
            limit: config.mcp_auth_failure_limit_per_minute,
            increment: true
          )
          unless fail_result[:allowed]
            return render_rate_limited(fail_result[:retry_after])
          end
        end

        response.set_header("WWW-Authenticate", 'Bearer realm="sentrace-mcp"')
        return render json: { error: "Unauthorized" }, status: :unauthorized
      end

      token_rate = RateLimiter.check!(
        bucket: "mcp",
        identifier: "tok:#{token_record.id}",
        limit: config.mcp_rate_limit_per_minute
      )
      unless token_rate[:allowed]
        return render_rate_limited(token_rate[:retry_after])
      end

      mcp_server = Mcp::Server.build(
        dispatcher: build_node_dispatcher(
          config,
          read_only: token_record.read_only?,
          allowed_project_id: token_record.project_id
        )
      )
      transport = ::MCP::Server::Transports::StreamableHTTPTransport.new(
        mcp_server,
        stateless: true,
        enable_json_response: true,
        dns_rebinding_protection: false,
        serve_subscriptions_listen: false,
        max_request_bytes: MAX_MCP_REQUEST_BYTES
      )

      rack_status, rack_headers, rack_body = transport.handle_request(Rack::Request.new(request.env))
      write_rack_response(rack_status, rack_headers, rack_body)
    end

    private
      def https_or_loopback?
        RequestSecurity.https_or_loopback?(request)
      end

      def rate_limit_identifier
        RequestSecurity.rate_limit_ip(request).presence || "unknown"
      end

      def render_rate_limited(retry_after)
        response.set_header("Retry-After", retry_after.to_s)
        render json: { error: "Rate limit exceeded" }, status: :too_many_requests
      end

      def extract_bearer_token
        auth_header = request.headers["Authorization"].to_s
        return nil if auth_header.bytesize > 1024

        match = auth_header.match(/\ABearer\s+(\S+)\z/i)
        match ? match[1] : nil
      end

      def build_node_dispatcher(config, read_only: false, allowed_project_id: nil)
        env_label = config.deployment_environment.to_s.strip
        env_label = "local" if env_label.empty?

        node_config = config.dup
        node_config.environments = { env_label.to_sym => { transport: :local } }
        Mcp::Dispatcher.new(
          config: node_config,
          remote_client: nil,
          read_only: read_only,
          allowed_project_id: allowed_project_id
        )
      end

      def write_rack_response(rack_status, rack_headers, rack_body)
        rack_headers.each do |key, value|
          next if key.to_s.casecmp("content-length").zero?
          next if RequestSecurity.security_header_key?(key)

          response.set_header(key, value)
        end
        RequestSecurity.apply_security_headers!(response)

        chunks = []
        rack_body.each { |chunk| chunks << chunk.to_s }
        rack_body.close if rack_body.respond_to?(:close)

        content_type = rack_headers["content-type"] || rack_headers["Content-Type"]
        self.content_type = content_type if content_type
        self.status = rack_status
        self.response_body = chunks.join
      end
  end
end
