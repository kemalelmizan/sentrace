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
      MAX_REMOTE_RESPONSE_BYTES = 1 * 1024 * 1024
      MAX_JSON_NESTING = 64
      MAX_REMOTE_SANITIZE_NODES = 2_048
      ALLOWED_TOP_LEVEL_KEYS = %w[
        environment
        remote_deployment_environment
        projects
        issues
        events
        issue
        event
        interval
        since
        until
        total_events
        buckets
        next_cursor
      ].freeze
      TELEMETRY_TOP_LEVEL_KEYS = %w[issues events issue event buckets].freeze
      ALLOWED_INTERVALS = %w[minute hour day].freeze
      ALLOWED_PROJECT_KEYS = %w[id slug name environment created_at].freeze
      ALLOWED_ISSUE_SUMMARY_KEYS = %w[
        id project_id environment fingerprint status level
        exception_type message first_seen_at last_seen_at event_count
        ingestion_sources
      ].freeze
      ALLOWED_ISSUE_DETAIL_KEYS = (ALLOWED_ISSUE_SUMMARY_KEYS + %w[
        release_distribution environment_distribution recent_events
      ]).freeze
      ALLOWED_EVENT_SUMMARY_KEYS = %w[
        id event_id project_id issue_id environment event_environment
        release platform request_id ingestion_source level logger culprit
        exception_type message occurred_at received_at
      ].freeze
      ALLOWED_EVENT_DETAIL_KEYS = (ALLOWED_EVENT_SUMMARY_KEYS + %w[
        exception raw_message request breadcrumbs tags contexts user
      ]).freeze
      ALLOWED_BUCKET_KEYS = %w[bucket_start count].freeze

      def initialize(http_requester: nil)
        @custom_requester = !http_requester.nil?
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
            if @custom_requester
              @http_requester.call(uri: uri, headers: headers, body: body, timeout: effective_timeout)
            else
              perform_net_http_post(
                uri: uri,
                headers: headers,
                body: body,
                timeout: effective_timeout,
                env_name: env_def.name
              )
            end
          end
        rescue McpRemoteError => e
          if e.environment.to_s.empty?
            raise McpRemoteError.new(e.message, environment: env_def.name, category: e.category)
          end
          raise
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
            "Accept" => REQUEST_ACCEPT,
            "Accept-Encoding" => "identity"
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
            reject_compressed_headers!(env_def, response.headers)
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
          node_budget = { remaining: MAX_REMOTE_SANITIZE_NODES * 2 }
          remote_env = RequestSecurity.sanitize_single_line(payload["environment"], max_chars: 64).to_s
          normalized = payload.slice(*ALLOWED_TOP_LEVEL_KEYS).merge("environment" => target_env)
          if !remote_env.empty? && remote_env != target_env
            normalized["remote_deployment_environment"] = remote_env
          end

          if normalized["projects"].is_a?(Array)
            normalized["projects"] = normalized["projects"].first(LocalBackend::MAX_LIMIT).filter_map do |item|
              next unless item.is_a?(Hash)
              clean_proj = sanitize_remote_hash(item.slice(*ALLOWED_PROJECT_KEYS), node_budget: node_budget).merge("environment" => target_env)
              clean_proj["created_at"] = sanitize_iso8601_timestamp(clean_proj["created_at"]) if clean_proj.key?("created_at")
              clean_proj
            end
          end

          if normalized["issues"].is_a?(Array)
            normalized["issues"] = normalized["issues"].first(LocalBackend::MAX_LIMIT).filter_map do |item|
              next unless item.is_a?(Hash)
              sanitize_remote_issue_hash(item.slice(*ALLOWED_ISSUE_SUMMARY_KEYS), target_env, node_budget: node_budget)
            end
          end

          if normalized["events"].is_a?(Array)
            normalized["events"] = normalized["events"].first(LocalBackend::MAX_LIMIT).filter_map do |item|
              next unless item.is_a?(Hash)
              sanitize_remote_event_hash(item.slice(*ALLOWED_EVENT_SUMMARY_KEYS), target_env, node_budget: node_budget)
            end
          end

          if normalized["buckets"].is_a?(Array)
            normalized["buckets"] = normalized["buckets"].first(LocalBackend::MAX_TREND_BUCKETS).filter_map do |item|
              next unless item.is_a?(Hash)
              clean_bucket = sanitize_remote_hash(item.slice(*ALLOWED_BUCKET_KEYS), node_budget: node_budget)
              clean_bucket["bucket_start"] = sanitize_iso8601_timestamp(clean_bucket["bucket_start"]) if clean_bucket.key?("bucket_start")
              clean_bucket["count"] = [ clean_bucket["count"].to_i, 0 ].max if clean_bucket.key?("count")
              clean_bucket
            end
          end

          if normalized["issue"].is_a?(Hash)
            clean_issue = sanitize_remote_issue_hash(normalized["issue"].slice(*ALLOWED_ISSUE_DETAIL_KEYS), target_env, node_budget: node_budget)
            if clean_issue["recent_events"].is_a?(Array)
              clean_issue["recent_events"] = clean_issue["recent_events"].first(LocalBackend::RECENT_EVENTS_PREVIEW_LIMIT).filter_map do |ev|
                next unless ev.is_a?(Hash)
                sanitize_remote_event_hash(ev.slice(*ALLOWED_EVENT_SUMMARY_KEYS), target_env, node_budget: node_budget)
              end
            end
            normalized["issue"] = clean_issue
          end

          if normalized["event"].is_a?(Hash)
            normalized["event"] = sanitize_remote_event_hash(normalized["event"].slice(*ALLOWED_EVENT_DETAIL_KEYS), target_env, node_budget: node_budget)
          end

          if normalized.key?("next_cursor")
            cursor = RequestSecurity.sanitize_single_line(normalized["next_cursor"], max_chars: LocalBackend::MAX_CURSOR_BYTES)
            normalized["next_cursor"] = (cursor && !cursor.empty?) ? cursor : nil
          end

          if normalized.key?("interval")
            clean_interval = RequestSecurity.sanitize_single_line(normalized["interval"], max_chars: 16).to_s.downcase
            if ALLOWED_INTERVALS.include?(clean_interval)
              normalized["interval"] = clean_interval
            else
              normalized.delete("interval")
            end
          end

          %w[since until].each do |ts_key|
            next unless normalized.key?(ts_key)

            normalized[ts_key] = sanitize_iso8601_timestamp(normalized[ts_key])
          end

          if normalized.key?("total_events")
            normalized["total_events"] = [ normalized["total_events"].to_i, 0 ].max
          end

          # Never trust a remote node's untrusted_telemetry_notice string; always stamp the local notice
          if TELEMETRY_TOP_LEVEL_KEYS.any? { |k| normalized.key?(k) }
            normalized["untrusted_telemetry_notice"] = LocalBackend::UNTRUSTED_TELEMETRY_NOTICE
          else
            normalized.delete("untrusted_telemetry_notice")
          end

          normalized
        end

        def sanitize_remote_issue_hash(raw_issue, target_env, node_budget:)
          clean = sanitize_remote_hash(raw_issue, node_budget: node_budget).merge("environment" => target_env)
          %w[first_seen_at last_seen_at].each do |ts_key|
            clean[ts_key] = sanitize_iso8601_timestamp(clean[ts_key]) if clean.key?(ts_key)
          end
          clean
        end

        def sanitize_remote_event_hash(raw_event, target_env, node_budget:)
          clean = sanitize_remote_hash(raw_event, node_budget: node_budget).merge("environment" => target_env)
          %w[occurred_at received_at].each do |ts_key|
            clean[ts_key] = sanitize_iso8601_timestamp(clean[ts_key]) if clean.key?(ts_key)
          end
          clean
        end

        def sanitize_iso8601_timestamp(raw_val)
          return nil if raw_val.nil?

          clean = RequestSecurity.sanitize_single_line(raw_val, max_chars: 64).to_s
          return nil if clean.empty?

          parsed = Time.iso8601(clean).utc
          return nil if parsed < LocalBackend::MIN_QUERY_TIME || parsed > LocalBackend::MAX_QUERY_TIME

          parsed.nsec.zero? ? parsed.iso8601 : parsed.iso8601(6)
        rescue ArgumentError
          nil
        end

        def reject_compressed_headers!(env_def, headers)
          return unless headers.is_a?(Hash)

          _, encoding = headers.find { |k, _| k.to_s.casecmp("content-encoding").zero? }
          clean_enc = encoding.to_s.strip.downcase
          return if clean_enc.empty? || clean_enc == "identity"

          raise McpRemoteError.new(
            "Unsupported compressed Content-Encoding from environment #{env_def.name}",
            environment: env_def.name,
            category: "protocol_error"
          )
        end

        def sanitize_remote_hash(value, depth: 0, node_budget: { remaining: MAX_REMOTE_SANITIZE_NODES })
          node_budget[:remaining] -= 1
          return "[TRUNCATED]" if node_budget[:remaining] < 0 || depth > 6

          case value
          when Hash
            out = {}
            value.first(64).each do |k, v|
              break if node_budget[:remaining] <= 0

              clean_k = Ingestion::EventNormalizer.truncate_utf8_bytes(
                Ingestion::EventNormalizer.strip_unsafe_characters(k.to_s, allow_newlines: false),
                128
              )
              out[clean_k] = sanitize_remote_hash(v, depth: depth + 1, node_budget: node_budget)
            end
            out
          when Array
            out = []
            value.first(100).each do |item|
              break if node_budget[:remaining] <= 0

              out << sanitize_remote_hash(item, depth: depth + 1, node_budget: node_budget)
            end
            out
          when String
            bounded = Ingestion::EventNormalizer.truncate_utf8_bytes(value, 16_384)
            cleaned = Ingestion::EventNormalizer.strip_unsafe_characters(bounded, allow_newlines: true)
            redacted = Ingestion::Sanitizer.redact_inline_secrets(cleaned)
            Ingestion::EventNormalizer.truncate_utf8_bytes(redacted, 8192)
          else
            value
          end
        end

        def scrub_secret(message, env_def)
          bounded = Ingestion::EventNormalizer.truncate_utf8_bytes(message.to_s, 4_096).to_s
          secret = env_def.token.to_s
          bounded = bounded.gsub(secret, "[REDACTED]") unless secret.empty?
          redacted = Ingestion::Sanitizer.redact_inline_secrets(bounded)
          RequestSecurity.sanitize_single_line(redacted, max_chars: 512).to_s
        end

        def perform_net_http_post(uri:, headers:, body:, timeout:, env_name: nil)
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
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f

          http.start do |conn|
            conn.request(request) do |response|
              status_code = response.code.to_i
              response_headers = response.each_header.to_h
              content_encoding = response_headers["content-encoding"].to_s.strip.downcase
              if !content_encoding.empty? && content_encoding != "identity"
                raise McpRemoteError.new(
                  "Unsupported compressed Content-Encoding from environment #{env_name}",
                  environment: env_name,
                  category: "protocol_error"
                )
              end
              response.read_body do |chunk|
                if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                  raise Timeout::Error, "execution expired"
                end

                body_buffer << chunk.b
                if body_buffer.bytesize > MAX_REMOTE_RESPONSE_BYTES
                  raise McpRemoteError.new(
                    "Remote MCP response exceeded #{MAX_REMOTE_RESPONSE_BYTES} bytes",
                    environment: env_name,
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
