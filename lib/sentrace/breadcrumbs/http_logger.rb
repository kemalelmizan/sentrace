module Sentrace
  module Breadcrumbs
    module HttpLogger
      @mutex = Mutex.new
      @active = false
      @installed = false

      class << self
        def activate!
          require "net/http" unless defined?(::Net::HTTP)

          @mutex.synchronize do
            install_patch! unless @installed
            @active = true
          end
        end

        def deactivate!
          @mutex.synchronize { @active = false }
        end

        def active?
          @mutex.synchronize { @active }
        end

        def should_record_request?(http, req)
          return false unless active?
          return false unless Sentrace.configuration.enabled
          return false if Thread.current[CaptureDispatcher::REENTRANCY_KEY]

          path = req&.path.to_s
          mount_path = cached_mount_path
          return false if path.include?("/sentrace/api/") || path.include?("/sentrace/mcp")
          if !mount_path.empty? && (path.include?("#{mount_path}/api/") || path.include?("#{mount_path}/mcp"))
            return false
          end

          full_url = build_raw_url(http, req)
          !internal_sentrace_url?(full_url)
        rescue StandardError
          false
        end

        def record_http_breadcrumb(http, req, status_code, started_at, error_class: nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(2)
          method = req&.method.to_s.upcase
          safe_url = Breadcrumbs.scrub_url(build_raw_url(http, req))
          level =
            if error_class || (status_code && status_code >= 500)
              "error"
            elsif status_code && status_code >= 400
              "warning"
            else
              "info"
            end

          data = {
            "method" => method,
            "url" => safe_url,
            "status_code" => status_code,
            "duration_ms" => duration_ms,
            "error" => error_class
          }.compact

          Sentrace.add_breadcrumb(
            type: "http",
            category: "net.http",
            level: level,
            message: "#{method} #{safe_url}".strip,
            data: data
          )
        rescue StandardError
          nil
        end

        private
          def install_patch!
            return if ::Net::HTTP.method_defined?(:__sentrace_orig_request)

            ::Net::HTTP.class_eval do
              alias_method :__sentrace_orig_request, :request

              def request(req, body = nil, &block)
                unless started? && ::Sentrace::Breadcrumbs::HttpLogger.should_record_request?(self, req)
                  return __sentrace_orig_request(req, body, &block)
                end

                started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                response = __sentrace_orig_request(req, body, &block)
                ::Sentrace::Breadcrumbs::HttpLogger.record_http_breadcrumb(self, req, response&.code&.to_i, started_at)
                response
              rescue StandardError => e
                if started_at
                  ::Sentrace::Breadcrumbs::HttpLogger.record_http_breadcrumb(
                    self,
                    req,
                    nil,
                    started_at,
                    error_class: e.class.name
                  )
                end
                raise
              end
            end

            @installed = true
          end

          def build_raw_url(http, req)
            raw_path = req&.path.to_s
            return raw_path if raw_path.start_with?("http://", "https://")

            scheme = http.use_ssl? ? "https" : "http"
            host = http.address.to_s
            port = http.port
            default_port = http.use_ssl? ? 443 : 80
            port_part = port && port != default_port ? ":#{port}" : ""
            normalized_path = raw_path.start_with?("/") ? raw_path : "/#{raw_path}"
            "#{scheme}://#{host}#{port_part}#{normalized_path}"
          end

          def cached_mount_path
            @mount_path ||= FrontendDsnResolver.detect_engine_mount_path.to_s.chomp("/")
          rescue StandardError
            "/sentrace"
          end

          def internal_sentrace_url?(raw_url)
            cfg = Sentrace.configuration
            cfg.environments.each_value do |env_def|
              next unless env_def.url

              return true if raw_url.start_with?(env_def.url.to_s)
            end
            false
          end
      end
    end
  end
end
