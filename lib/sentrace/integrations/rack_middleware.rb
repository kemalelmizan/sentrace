require "rack/request"

module Sentrace
  module Integrations
    class RackMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        Sentrace.clear_scope!
        populate_request_scope(env)

        begin
          response = @app.call(env)
          downstream_exception = extract_downstream_exception(env)
          if downstream_exception
            populate_controller_culprit(env)
            ExceptionDeduplicator.capture_unhandled_once(downstream_exception, mechanism_type: "rack")
          end
          response
        rescue Exception => e # rubocop:disable Lint/RescueException
          unless system_exit_or_signal?(e)
            populate_controller_culprit(env)
            ExceptionDeduplicator.capture_unhandled_once(e, mechanism_type: "rack")
          end
          raise
        ensure
          Sentrace.clear_scope!
        end
      end

      private
        def populate_request_scope(env)
          return unless env.is_a?(Hash)

          raw_url = extract_raw_url(env)
          safe_url = Ingestion::Sanitizer.sanitize_url(raw_url)
          method = env["REQUEST_METHOD"].to_s.strip.upcase
          request_id = (env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]).to_s.strip

          request_payload = {}
          request_payload["url"] = safe_url if safe_url && !safe_url.empty?
          request_payload["method"] = method unless method.empty?

          scope = Sentrace.current_scope
          if request_id.match?(Ingestion::EventNormalizer::SAFE_REQUEST_ID_REGEX)
            request_payload["headers"] = { "X-Request-Id" => request_id }
            scope.set_tag("request_id", request_id)
          end

          scope.set_request(request_payload) unless request_payload.empty?
        rescue StandardError
          nil
        end

        def populate_controller_culprit(env)
          return unless env.is_a?(Hash)
          return if Sentrace.current_scope.transaction_name

          path_params = env["action_dispatch.request.path_parameters"]
          return unless path_params.is_a?(Hash)

          controller = (path_params[:controller] || path_params["controller"]).to_s
          action = (path_params[:action] || path_params["action"]).to_s
          return if controller.empty? || action.empty?

          Sentrace.current_scope.set_transaction_name("#{controller.camelize}Controller##{action}")
        rescue StandardError
          nil
        end

        def extract_raw_url(env)
          Rack::Request.new(env).url
        rescue StandardError
          env["PATH_INFO"].to_s
        end

        def extract_downstream_exception(env)
          return nil unless env.is_a?(Hash)

          candidate = env["action_dispatch.exception"] || env["rack.exception"] || env["sinatra.error"]
          candidate.is_a?(Exception) ? candidate : nil
        end

        def system_exit_or_signal?(exception)
          exception.is_a?(SystemExit) || exception.is_a?(SignalException)
        end
    end
  end
end
