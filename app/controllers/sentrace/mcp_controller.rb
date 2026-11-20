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

      rate_result = RateLimiter.check!(
        bucket: "mcp",
        identifier: client_ip,
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

      token_record = authenticate_bearer_token
      unless token_record
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

      mcp_server = Mcp::Server.build(
        dispatcher: build_node_dispatcher(config, read_only: token_record.read_only?)
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
        RequestSecurity.client_ip(request).presence || "unknown"
      end

      def render_rate_limited(retry_after)
        response.set_header("Retry-After", retry_after.to_s)
        render json: { error: "Rate limit exceeded" }, status: :too_many_requests
      end

      def authenticate_bearer_token
        auth_header = request.headers["Authorization"].to_s
        return nil if auth_header.bytesize > 1024

        match = auth_header.match(/\ABearer\s+(\S+)\z/i)
        return nil unless match

        McpToken.authenticate(match[1])
      end

      def build_node_dispatcher(config, read_only: false)
        env_label = config.deployment_environment.to_s.strip
        env_label = "local" if env_label.empty?

        node_config = config.dup
        node_config.environments = { env_label.to_sym => { transport: :local } }
        Mcp::Dispatcher.new(config: node_config, remote_client: nil, read_only: read_only)
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
