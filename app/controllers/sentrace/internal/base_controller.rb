module Sentrace
  module Internal
    class BaseController < ApplicationController
      MAX_INTERNAL_REQUEST_BYTES = 64.kilobytes
      BODY_CHECK_CHUNK_BYTES = 16 * 1024

      before_action :verify_https_or_loopback!
      before_action :verify_internal_ip_allowlist!
      before_action :verify_request_origin_and_csrf!
      before_action :verify_internal_rate_limit!
      before_action :verify_request_body_bounds!
      before_action :authenticate_internal_request!

      # Guard against Rails' ActionController::Instrumentation eagerly parsing oversized
      # or multipart request bodies before before_action filters run.
      def process_action(*)
        if multipart_or_oversized_body?
          request.set_header("action_dispatch.request.request_parameters", {})
        end
        super
      end

      rescue_from ActiveRecord::RecordNotFound do |err|
        render json: { error: err.message }, status: :not_found
      end

      rescue_from ActiveRecord::RecordInvalid do |err|
        render json: { error: err.record.errors.full_messages.join(", ") }, status: 422
      end

      rescue_from McpNotFoundError do |err|
        render json: { error: err.message }, status: :not_found
      end

      rescue_from McpForbiddenError do |err|
        render json: { error: err.message }, status: :forbidden
      end

      rescue_from McpInvalidParamsError do |err|
        render json: { error: err.message }, status: 422
      end

      rescue_from ActiveModel::RangeError do
        render json: { error: "Parameter value out of range" }, status: 422
      end

      private
        def verify_https_or_loopback!
          unless RequestSecurity.https_or_loopback?(request)
            render json: { error: "HTTPS is required for non-local internal endpoints" }, status: :forbidden
          end
        end

        def verify_internal_ip_allowlist!
          unless RequestSecurity.ip_allowed?(request, Sentrace.configuration.internal_allowed_ips)
            render json: { error: "IP address not allowed" }, status: :forbidden
          end
        end

        def verify_request_origin_and_csrf!
          if RequestSecurity.forbidden_cross_origin?(request) || RequestSecurity.forbidden_cookie_csrf?(request)
            render json: { error: "Forbidden" }, status: :forbidden
          end
        end

        def verify_internal_rate_limit!
          config = Sentrace.configuration
          if config.internal_authenticator.nil?
            raw_bearer = extract_bearer_token
            return if raw_bearer && McpToken.recently_verified_raw_token?(raw_bearer)
          end

          rate_result = RateLimiter.check!(
            bucket: "internal",
            identifier: "ip:#{rate_limit_identifier}",
            limit: config.mcp_rate_limit_per_minute
          )
          unless rate_result[:allowed]
            render_rate_limited(rate_result[:retry_after])
          end
        end

        def verify_request_body_bounds!
          if request.media_type.to_s.casecmp("multipart/form-data").zero?
            return render json: { error: "Unsupported media type" }, status: :unsupported_media_type
          end

          if oversized_request_body?
            render json: { error: "Payload too large" }, status: 413
          end
        end

        def multipart_or_oversized_body?
          request.media_type.to_s.casecmp("multipart/form-data").zero? || oversized_request_body?
        end

        def oversized_request_body?
          return @oversized_request_body unless @oversized_request_body.nil?

          if request.content_length && request.content_length > MAX_INTERNAL_REQUEST_BYTES
            return @oversized_request_body = true
          end

          io = request.body
          return @oversized_request_body = false unless io

          io.rewind if io.respond_to?(:rewind)
          total = 0
          while (chunk = io.read(BODY_CHECK_CHUNK_BYTES))
            total += chunk.bytesize
            if total > MAX_INTERNAL_REQUEST_BYTES
              return @oversized_request_body = true
            end
          end
          io.rewind if io.respond_to?(:rewind)
          @oversized_request_body = false
        end

        def authenticate_internal_request!
          config = Sentrace.configuration
          client_ip = rate_limit_identifier
          custom_auth = config.internal_authenticator

          if custom_auth
            if config.mcp_auth_failure_limit_per_minute
              auth_precheck = RateLimiter.check!(
                bucket: "mcp_auth_fail",
                identifier: client_ip,
                limit: config.mcp_auth_failure_limit_per_minute,
                increment: false
              )
              if auth_precheck[:count] >= config.mcp_auth_failure_limit_per_minute
                render_rate_limited(auth_precheck[:retry_after])
                return
              end
            end

            auth_result = custom_auth.arity == 2 || custom_auth.arity < 0 ? custom_auth.call(request, required_internal_scope) : custom_auth.call(request)
            if apply_custom_auth_result!(auth_result)
              return
            end

            if record_auth_failure_and_check_throttled?(client_ip, config)
              return
            end

            render json: { error: "Unauthorized" }, status: :unauthorized
            return
          end

          bearer = extract_bearer_token
          known_verified = bearer && McpToken.recently_verified_raw_token?(bearer)

          if !known_verified && config.mcp_auth_failure_limit_per_minute
            auth_precheck = RateLimiter.check!(
              bucket: "mcp_auth_fail",
              identifier: client_ip,
              limit: config.mcp_auth_failure_limit_per_minute,
              increment: false
            )
            if auth_precheck[:count] >= config.mcp_auth_failure_limit_per_minute
              render_rate_limited(auth_precheck[:retry_after])
              return
            end
          end

          @current_mcp_token = bearer ? McpToken.authenticate(bearer) : nil
          if @current_mcp_token
            token_rate = RateLimiter.check!(
              bucket: "internal",
              identifier: "tok:#{@current_mcp_token.id}",
              limit: config.mcp_rate_limit_per_minute
            )
            unless token_rate[:allowed]
              render_rate_limited(token_rate[:retry_after])
            end
            return
          end

          if known_verified
            ip_rate = RateLimiter.check!(
              bucket: "internal",
              identifier: "ip:#{client_ip}",
              limit: config.mcp_rate_limit_per_minute
            )
            unless ip_rate[:allowed]
              render_rate_limited(ip_rate[:retry_after])
              return
            end
          end

          if record_auth_failure_and_check_throttled?(client_ip, config)
            return
          end

          response.set_header("WWW-Authenticate", 'Bearer realm="sentrace-internal"')
          render json: { error: "Unauthorized" }, status: :unauthorized
        end

        def extract_bearer_token
          auth_header = request.headers["Authorization"].to_s
          auth_header.bytesize <= 1024 ? auth_header[/\ABearer\s+(\S+)\z/i, 1] : nil
        end

        def record_auth_failure_and_check_throttled?(client_ip, config)
          return false unless config.mcp_auth_failure_limit_per_minute

          fail_result = RateLimiter.check!(
            bucket: "mcp_auth_fail",
            identifier: client_ip,
            limit: config.mcp_auth_failure_limit_per_minute,
            increment: true
          )
          return false if fail_result[:allowed]

          render_rate_limited(fail_result[:retry_after])
          true
        end

        def rate_limit_identifier
          RequestSecurity.rate_limit_ip(request).presence || "unknown"
        end

        def render_rate_limited(retry_after)
          response.set_header("Retry-After", retry_after.to_s)
          render json: { error: "Rate limit exceeded" }, status: :too_many_requests
        end

        def apply_custom_auth_result!(auth_result)
          return false unless auth_result

          if auth_result.is_a?(Hash)
            scopes =
              if auth_result[:read_only] == true || auth_result["read_only"] == true
                %w[read]
              elsif auth_result[:admin] == true || auth_result["admin"] == true
                %w[read write admin]
              else
                raw_scopes = auth_result[:scopes] || auth_result["scopes"]
                Array(raw_scopes.is_a?(String) ? raw_scopes.split(",") : raw_scopes)
                  .map { |s| s.to_s.strip.downcase }
                  .reject(&:empty?)
              end
            @current_internal_scopes = scopes
          else
            @current_internal_scopes = %w[read write admin]
          end
          true
        end

        def required_internal_scope
          if self.class.name == "Sentrace::Internal::ProjectsController" && %w[create update destroy].include?(action_name)
            :admin
          elsif request.get? || request.head? || request.options?
            :read
          else
            :write
          end
        end

        def require_write_scope!
          if @current_mcp_token&.read_only? || (@current_internal_scopes && !@current_internal_scopes.include?("write") && !@current_internal_scopes.include?("admin"))
            render json: { error: "Forbidden: read-only credentials cannot mutate resources" }, status: :forbidden
          end
        end

        def require_admin_scope!
          if (@current_mcp_token && !@current_mcp_token.admin?) || (@current_internal_scopes && !@current_internal_scopes.include?("admin"))
            render json: { error: "Forbidden: admin scope is required to mutate projects" }, status: :forbidden
          end
        end

        def can_view_project_credentials?
          return @current_internal_scopes.include?("admin") if @current_internal_scopes

          @current_mcp_token.nil? || @current_mcp_token.admin?
        end

        def scalar_param(key)
          RequestSecurity.scalar_param(params, key)
        end

        def local_backend
          @local_backend ||= Mcp::LocalBackend.new(
            environment_name: Sentrace.configuration.deployment_environment.to_s,
            allowed_project_id: @current_mcp_token&.project_id
          )
        end
    end
  end
end
