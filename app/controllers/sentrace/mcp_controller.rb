require "mcp"
require "rack"

module Sentrace
  class McpController < ApplicationController
    MAX_MCP_REQUEST_BYTES = 1.megabyte

    def handle
      unless https_or_loopback?
        return render json: { error: "HTTPS is required for non-local MCP endpoints" }, status: :forbidden
      end

      token_record = authenticate_bearer_token
      unless token_record
        response.set_header("WWW-Authenticate", 'Bearer realm="sentrace-mcp"')
        return render json: { error: "Unauthorized" }, status: :unauthorized
      end

      mcp_server = Mcp::Server.build(dispatcher: build_node_dispatcher(Sentrace.configuration))
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
        return true if request.ssl?

        Configuration::LOOPBACK_HOSTS.include?(request.host.to_s.downcase)
      end

      def authenticate_bearer_token
        auth_header = request.headers["Authorization"].to_s
        match = auth_header.match(/\ABearer\s+(\S+)\z/i)
        return nil unless match

        McpToken.authenticate(match[1])
      end

      def build_node_dispatcher(config)
        env_label = config.deployment_environment.to_s.strip
        env_label = "local" if env_label.empty?

        node_config = config.dup
        node_config.environments = { env_label.to_sym => { transport: :local } }
        Mcp::Dispatcher.new(config: node_config, remote_client: nil)
      end

      def write_rack_response(rack_status, rack_headers, rack_body)
        rack_headers.each do |key, value|
          next if key.to_s.casecmp("content-length").zero?

          response.set_header(key, value)
        end

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
