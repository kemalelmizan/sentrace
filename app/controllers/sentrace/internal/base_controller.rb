module Sentrace
  module Internal
    class BaseController < ApplicationController
      before_action :authenticate_internal_request!

      rescue_from ActiveRecord::RecordNotFound do |err|
        render json: { error: err.message }, status: :not_found
      end

      rescue_from ActiveRecord::RecordInvalid do |err|
        render json: { error: err.record.errors.full_messages.join(", ") }, status: :unprocessable_content
      end

      rescue_from McpNotFoundError do |err|
        render json: { error: err.message }, status: :not_found
      end

      rescue_from McpInvalidParamsError do |err|
        render json: { error: err.message }, status: :unprocessable_content
      end

      private
        def authenticate_internal_request!
          custom_auth = Sentrace.configuration.internal_authenticator
          if custom_auth
            return if custom_auth.call(request)

            render json: { error: "Unauthorized" }, status: :unauthorized
            return
          end

          auth_header = request.headers["Authorization"].to_s
          bearer = auth_header[/\ABearer\s+(\S+)\z/i, 1]
          return if McpToken.authenticate(bearer)

          response.set_header("WWW-Authenticate", 'Bearer realm="sentrace-internal"')
          render json: { error: "Unauthorized" }, status: :unauthorized
        end

        def local_backend
          @local_backend ||= Mcp::LocalBackend.new(
            environment_name: Sentrace.configuration.deployment_environment.to_s
          )
        end
    end
  end
end
