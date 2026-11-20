module Sentrace
  module Internal
    class BaseController < ApplicationController
      before_action :verify_internal_ip_allowlist!
      before_action :verify_request_origin_and_csrf!
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

        def authenticate_internal_request!
          custom_auth = Sentrace.configuration.internal_authenticator
          if custom_auth
            return if custom_auth.call(request)

            render json: { error: "Unauthorized" }, status: :unauthorized
            return
          end

          auth_header = request.headers["Authorization"].to_s
          bearer = auth_header.bytesize <= 1024 ? auth_header[/\ABearer\s+(\S+)\z/i, 1] : nil
          @current_mcp_token = McpToken.authenticate(bearer)
          return if @current_mcp_token

          response.set_header("WWW-Authenticate", 'Bearer realm="sentrace-internal"')
          render json: { error: "Unauthorized" }, status: :unauthorized
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
