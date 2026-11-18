require "rack/request"

module Sentrace
  module Integrations
    class RackMiddleware
      PUMA_STREAM_CLOSED_REGEX = /\bstream closed in another thread\b/i

      def initialize(app)
        @app = app
      end

      def call(env)
        Sentrace.clear_scope!
        populate_request_scope(env)

        begin
          response = @app.call(env)
          downstream_exception = extract_downstream_exception(env)
          if downstream_exception && !ignorable_client_disconnect?(downstream_exception)
            populate_controller_culprit(env)
            ExceptionDeduplicator.capture_unhandled_once(downstream_exception, mechanism_type: "rack")
          end
          response
        rescue Exception => e # rubocop:disable Lint/RescueException
          unless system_exit_or_signal?(e) || ignorable_client_disconnect?(e)
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
          if path_params.is_a?(Hash)
            controller = (path_params[:controller] || path_params["controller"]).to_s
            action = (path_params[:action] || path_params["action"]).to_s
            if !controller.empty? && !action.empty?
              Sentrace.current_scope.set_transaction_name("#{controller.camelize}Controller##{action}")
              return
            end
          end

          fallback = extract_fallback_culprit(env)
          Sentrace.current_scope.set_transaction_name(fallback) if fallback
        rescue StandardError
          nil
        end

        def extract_fallback_culprit(env)
          method = env["REQUEST_METHOD"].to_s.strip.upcase
          raw_path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}".split("?", 2).first.to_s.strip
          raw_path = "/" if raw_path.empty?
          return nil if method.empty? && env["PATH_INFO"].to_s.strip.empty? && env["SCRIPT_NAME"].to_s.strip.empty?

          method.empty? ? raw_path : "#{method} #{raw_path}"
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

        def ignorable_client_disconnect?(exception)
          return false unless exception.is_a?(IOError)
          return false unless exception.message.to_s.match?(PUMA_STREAM_CLOSED_REGEX)

          !EventBuilder.any_in_app_frame?(exception, config: Sentrace.configuration)
        rescue StandardError
          false
        end

        def system_exit_or_signal?(exception)
          exception.is_a?(SystemExit) || exception.is_a?(SignalException)
        end
    end
  end
end
