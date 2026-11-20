module Sentrace
  module Internal
    class BaseController < ApplicationController
      before_action :verify_https_or_loopback!
      before_action :verify_internal_ip_allowlist!
      before_action :verify_request_origin_and_csrf!
      before_action :verify_internal_rate_limit!
      before_action :authenticate_internal_request!

      rescue_from ActiveRecord::RecordNotFound do |err|
        render json: { error: err.message }, status: :not_found
      end

      rescue_from ActiveRecord::RecordInvalid do |err|
        render json: { error: err.record.errors.full_messages.join(", ") }, status: 422
      end

      rescue_from McpNotFoundError do |err|
        render json: { error: err.message }, status: :not_found
      end

      rescue_from McpInvalidParamsError do |err|
        render json: { error: err.message }, status: 422
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
          rate_result = RateLimiter.check!(
            bucket: "internal",
            identifier: rate_limit_identifier,
            limit: config.mcp_rate_limit_per_minute
          )
          unless rate_result[:allowed]
            render_rate_limited(rate_result[:retry_after])
          end
        end

        def authenticate_internal_request!
          config = Sentrace.configuration
          client_ip = rate_limit_identifier

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

          custom_auth = config.internal_authenticator
          if custom_auth
            return if custom_auth.call(request)

            if record_auth_failure_and_check_throttled?(client_ip, config)
              return
            end

            render json: { error: "Unauthorized" }, status: :unauthorized
            return
          end

          auth_header = request.headers["Authorization"].to_s
          bearer = auth_header.bytesize <= 1024 ? auth_header[/\ABearer\s+(\S+)\z/i, 1] : nil
          @current_mcp_token = McpToken.authenticate(bearer)
          return if @current_mcp_token

          if record_auth_failure_and_check_throttled?(client_ip, config)
            return
          end

          response.set_header("WWW-Authenticate", 'Bearer realm="sentrace-internal"')
          render json: { error: "Unauthorized" }, status: :unauthorized
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
          request.remote_ip.to_s.strip.presence || "unknown"
        end

        def render_rate_limited(retry_after)
          response.set_header("Retry-After", retry_after.to_s)
          render json: { error: "Rate limit exceeded" }, status: :too_many_requests
        end

        def require_write_scope!
          if @current_mcp_token&.read_only?
            render json: { error: "Forbidden: read-only token cannot mutate resources" }, status: :forbidden
          end
        end

        def require_admin_scope!
          if @current_mcp_token && !@current_mcp_token.admin?
            render json: { error: "Forbidden: admin scope is required to mutate projects" }, status: :forbidden
          end
        end

        def can_view_project_credentials?
          @current_mcp_token.nil? || @current_mcp_token.admin?
        end

        def scalar_param(key)
          RequestSecurity.scalar_param(params, key)
        end

        def local_backend
          @local_backend ||= Mcp::LocalBackend.new(
            environment_name: Sentrace.configuration.deployment_environment.to_s
          )
        end
    end
  end
end
