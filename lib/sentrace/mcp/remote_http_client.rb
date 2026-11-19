require "json"
require "openssl"
require "securerandom"
require "timeout"
require "uri"

module Sentrace
  module Mcp
    class RemoteHttpClient
      HttpResponse = Data.define(:status, :headers, :body)

      SUPPORTED_OPERATIONS = %w[
        list_projects
        list_issues
        get_issue
        update_issue_status
        list_events
        get_event
        get_error_trends
      ].freeze

      REQUEST_CONTENT_TYPE = "application/json".freeze
      REQUEST_ACCEPT = "application/json, text/event-stream".freeze
      MAX_REMOTE_RESPONSE_BYTES = 4 * 1024 * 1024
      MAX_JSON_NESTING = 64

      def initialize(http_requester: nil)
        @http_requester = http_requester || method(:perform_net_http_post)
      end

      def call_environment(env_def, operation, **kwargs)
        op_name = operation.to_s
        unless SUPPORTED_OPERATIONS.include?(op_name)
          raise McpInvalidParamsError, "Unsupported remote MCP operation #{op_name.inspect}"
        end

        arguments = kwargs.compact.transform_keys(&:to_s)
        body = JSON.generate(
          jsonrpc: "2.0",
          id: SecureRandom.uuid,
          method: "tools/call",
          params: {
            name: op_name,
            arguments: arguments
          }
        )

        response = post_json_rpc(env_def, body)
        unwrap_tool_response!(env_def, response)
      end

      def environment_status(env_def, timeout: nil)
        return "unconfigured" if unconfigured_http_environment?(env_def)

        body = JSON.generate(
          jsonrpc: "2.0",
          id: "ping",
          method: "ping",
          params: {}
        )
        response = post_json_rpc(env_def, body, timeout: timeout)

        case response.status
        when 200..299
          raw_body = response.body.to_s
          return "protocol_error" if raw_body.bytesize > MAX_REMOTE_RESPONSE_BYTES

          parsed = JSON.parse(raw_body, max_nesting: MAX_JSON_NESTING)
          parsed.is_a?(Hash) && parsed.key?("result") ? "connected" : "protocol_error"
        when 401, 403
          "authentication_failed"
        else
          "unreachable"
        end
      rescue McpRemoteError => e
        e.category
      rescue JSON::ParserError, JSON::NestingError
        "protocol_error"
      end

      private
        def unconfigured_http_environment?(env_def)
          env_def.url.to_s.strip.empty? || env_def.token.to_s.strip.empty?
        end

        def post_json_rpc(env_def, body, timeout: nil)
          uri = validate_endpoint!(env_def)
          headers = build_headers(env_def)
          effective_timeout = timeout || env_def.timeout

          run_with_deadline(effective_timeout) do
            @http_requester.call(uri: uri, headers: headers, body: body, timeout: effective_timeout)
          end
        rescue McpError
          raise
        rescue Timeout::Error
          raise McpRemoteError.new(
            "Timed out after #{effective_timeout}s querying environment #{env_def.name}",
            environment: env_def.name,
            category: "timeout"
          )
        rescue SocketError, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
          raise McpRemoteError.new(
            "Could not reach environment #{env_def.name}",
            environment: env_def.name,
            category: "unreachable"
          )
        end

        def run_with_deadline(timeout)
          worker = Thread.new do
            Thread.current.report_on_exception = false
            begin
              yield
            ensure
              ActiveRecord::Base.connection_handler.clear_active_connections! if defined?(ActiveRecord::Base)
            end
          end

          return worker.value if worker.join(timeout)

          worker.kill
          raise Timeout::Error, "execution expired"
        end

        def validate_endpoint!(env_def)
          raw_url = env_def.url.to_s.strip
          raw_token = env_def.token.to_s.strip
          if raw_url.empty? || raw_token.empty?
            raise McpRemoteError.new(
              "Remote MCP URL or bearer token is not configured for environment #{env_def.name}",
              environment: env_def.name,
              category: "unconfigured"
            )
          end

          if raw_token.match?(/[\s\x00-\x1F\x7F]/)
            raise McpRemoteError.new(
              "Invalid MCP bearer token format for environment #{env_def.name}",
              environment: env_def.name,
              category: "invalid_endpoint"
            )
          end

          uri = URI.parse(raw_url)
          unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? && uri.fragment.nil?
            raise McpRemoteError.new(
              "Invalid MCP endpoint URL for environment #{env_def.name}",
              environment: env_def.name,
              category: "invalid_endpoint"
            )
          end

          if uri.scheme != "https" && !RequestSecurity.loopback_host?(uri.host)
            raise McpRemoteError.new(
              "HTTPS is required for remote environment #{env_def.name}",
              environment: env_def.name,
              category: "insecure_transport"
            )
          end

          uri
        rescue URI::InvalidURIError
          raise McpRemoteError.new(
            "Malformed MCP endpoint URL for environment #{env_def.name}",
            environment: env_def.name,
            category: "invalid_endpoint"
          )
        end

        def build_headers(env_def)
          headers = {
            "Content-Type" => REQUEST_CONTENT_TYPE,
            "Accept" => REQUEST_ACCEPT
          }
          token = env_def.token.to_s.strip
          headers["Authorization"] = "Bearer #{token}" unless token.empty?
          headers
        end

        def unwrap_tool_response!(env_def, response)
          status = response.status.to_i

          case status
          when 401, 403
            raise McpRemoteError.new(
              "Authentication failed for environment #{env_def.name} (HTTP #{status})",
              environment: env_def.name,
              category: "authentication_failed"
            )
          when 404
            raise McpRemoteError.new(
              "MCP endpoint not found for environment #{env_def.name} (HTTP 404)",
              environment: env_def.name,
              category: "unreachable"
            )
          when 413
            raise McpRemoteError.new(
              "Request payload rejected as too large by environment #{env_def.name}",
              environment: env_def.name,
              category: "protocol_error"
            )
          when 200..299
            parse_json_rpc_result!(env_def, response.body.to_s)
          else
            raise McpRemoteError.new(
              "Remote environment #{env_def.name} returned HTTP #{status}",
              environment: env_def.name,
              category: "unreachable"
            )
          end
        end

        def parse_json_rpc_result!(env_def, raw_body)
          if raw_body.bytesize > MAX_REMOTE_RESPONSE_BYTES
            raise McpRemoteError.new(
              "Response from environment #{env_def.name} exceeded #{MAX_REMOTE_RESPONSE_BYTES} bytes",
              environment: env_def.name,
              category: "protocol_error"
            )
          end

          parsed = JSON.parse(raw_body, max_nesting: MAX_JSON_NESTING)
          unless parsed.is_a?(Hash)
            raise McpRemoteError.new(
              "Malformed JSON-RPC envelope from environment #{env_def.name}",
              environment: env_def.name,
              category: "protocol_error"
            )
          end

          if parsed["error"].is_a?(Hash)
            rpc_msg = scrub_secret(parsed.dig("error", "message") || "JSON-RPC error", env_def)
            raise McpRemoteError.new(
              "Remote MCP error from #{env_def.name}: #{rpc_msg}",
              environment: env_def.name,
              category: "protocol_error"
            )
          end

          result = parsed["result"]
          unless result.is_a?(Hash)
            raise McpRemoteError.new(
              "Missing JSON-RPC result from environment #{env_def.name}",
              environment: env_def.name,
              category: "protocol_error"
            )
          end

          structured = result["structuredContent"] || parse_text_content_fallback(result["content"])

          if result["isError"] == true
            handle_remote_tool_error!(env_def, structured)
          end

          unless structured.is_a?(Hash)
            raise McpRemoteError.new(
              "Missing structured tool payload from environment #{env_def.name}",
              environment: env_def.name,
              category: "protocol_error"
            )
          end

          normalize_environment_attribution(structured, env_def.name.to_s)
        rescue JSON::ParserError, JSON::NestingError
          raise McpRemoteError.new(
            "Invalid JSON response from environment #{env_def.name}",
            environment: env_def.name,
            category: "protocol_error"
          )
        end

        def handle_remote_tool_error!(env_def, structured)
          category = structured.is_a?(Hash) ? structured["category"].to_s : ""
          raw_msg = structured.is_a?(Hash) ? structured["error"] : nil
          safe_msg = scrub_secret(raw_msg || "Remote tool execution failed in #{env_def.name}", env_def)

          case category
          when "not_found"
            raise McpNotFoundError, safe_msg
          when "invalid_params"
            raise McpInvalidParamsError, safe_msg
          else
            raise McpRemoteError.new(
              safe_msg,
              environment: env_def.name,
              category: "remote_tool_error"
            )
          end
        end

        def parse_text_content_fallback(content_list)
          return nil unless content_list.is_a?(Array)

          first_text = content_list.find { |item| item.is_a?(Hash) && item["type"] == "text" && item["text"].is_a?(String) }
          return nil unless first_text
          return nil if first_text["text"].bytesize > MAX_REMOTE_RESPONSE_BYTES

          JSON.parse(first_text["text"], max_nesting: MAX_JSON_NESTING)
        rescue JSON::ParserError, JSON::NestingError
          nil
        end

        def normalize_environment_attribution(payload, target_env)
          remote_env = payload["environment"].to_s.strip
          normalized = payload.merge("environment" => target_env)
          if !remote_env.empty? && remote_env != target_env
            normalized["remote_deployment_environment"] = remote_env
          end

          %w[projects issues events].each do |collection_key|
            next unless normalized[collection_key].is_a?(Array)

            normalized[collection_key] = normalized[collection_key].map do |item|
              item.is_a?(Hash) ? item.merge("environment" => target_env) : item
            end
          end

          %w[issue event].each do |record_key|
            next unless normalized[record_key].is_a?(Hash)

            normalized[record_key] = normalized[record_key].merge("environment" => target_env)
          end

          normalized
        end

        def scrub_secret(message, env_def)
          text = message.to_s.dup
          secret = env_def.token.to_s
          text.gsub!(secret, "[REDACTED]") unless secret.empty?
          text
        end

        def perform_net_http_post(uri:, headers:, body:, timeout:)
          require "net/http"
          target_host = uri.respond_to?(:hostname) && uri.hostname ? uri.hostname : uri.host
          http = Net::HTTP.new(target_host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          if http.use_ssl?
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            http.min_version = OpenSSL::SSL::TLS1_2_VERSION if http.respond_to?(:min_version=)
          end
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.write_timeout = timeout if http.respond_to?(:write_timeout=)
          http.ssl_timeout = timeout if http.respond_to?(:ssl_timeout=)
          http.max_retries = 0 if http.respond_to?(:max_retries=)

          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = body

          status_code = nil
          response_headers = nil
          body_buffer = "".b

          http.start do |conn|
            conn.request(request) do |response|
              status_code = response.code.to_i
              response_headers = response.each_header.to_h
              response.read_body do |chunk|
                body_buffer << chunk.b
                if body_buffer.bytesize > MAX_REMOTE_RESPONSE_BYTES
                  raise McpRemoteError.new(
                    "Remote MCP response exceeded #{MAX_REMOTE_RESPONSE_BYTES} bytes",
                    environment: target_host,
                    category: "protocol_error"
                  )
                end
              end
            end
          end

          HttpResponse.new(
            status: status_code,
            headers: response_headers || {},
            body: body_buffer.force_encoding(Encoding::UTF_8)
          )
        rescue McpRemoteError => e
          raise e
        end
    end
  end
end
