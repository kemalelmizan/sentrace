module Sentrace
  module Integrations
    module Sidekiq
      SIDEKIQ_ACTIVE_THREAD_KEY = :sentrace_sidekiq_active

      class ServerMiddleware
        def call(_worker, job, queue)
          Sentrace.clear_scope!
          Thread.current[SIDEKIQ_ACTIVE_THREAD_KEY] = true
          Sidekiq.apply_job_scope(job, queue: queue)

          succeeded = false
          result = yield
          succeeded = true
          result
        ensure
          Thread.current[SIDEKIQ_ACTIVE_THREAD_KEY] = false
          # When an unhandled exception escapes `yield`, preserve the current thread's scope
          # momentarily so `Sidekiq::ErrorHandler` (which runs immediately outside middleware)
          # retains all breadcrumbs, tags, and Sidekiq context before clearing the scope.
          Sentrace.clear_scope! if succeeded
        end
      end

      class ErrorHandler
        def call(exception, context = {}, _sidekiq_config = nil)
          return unless exception.is_a?(Exception)

          job = context.is_a?(Hash) ? (context[:job] || context["job"]) : nil
          Sidekiq.apply_job_scope(job) if job.is_a?(Hash) && !Sentrace.current_scope.contexts.key?("sidekiq")

          ExceptionDeduplicator.capture_unhandled_once(exception, mechanism_type: "sidekiq")
        ensure
          Sentrace.clear_scope!
        end
      end

      ERROR_HANDLER = ErrorHandler.new.freeze

      class << self
        def install!(sidekiq_mod = (defined?(::Sidekiq) ? ::Sidekiq : nil))
          return false unless sidekiq_mod && sidekiq_mod.respond_to?(:configure_server)

          sidekiq_mod.configure_server do |config|
            install_into_config!(config)
          end
          true
        end

        def install_into_config!(config)
          if config.respond_to?(:server_middleware)
            config.server_middleware do |chain|
              exists = chain.respond_to?(:exists?) ? chain.exists?(ServerMiddleware) : false
              chain.add(ServerMiddleware) unless exists
            end
          end

          if config.respond_to?(:error_handlers) && config.error_handlers.is_a?(Array)
            unless config.error_handlers.include?(ERROR_HANDLER)
              config.error_handlers << ERROR_HANDLER
            end
          end

          if config.respond_to?(:on)
            register_lifecycle_hooks_once!(config)
          end
        end

        def active_in_current_thread?
          Thread.current[SIDEKIQ_ACTIVE_THREAD_KEY] == true
        end

        def apply_job_scope(job, queue: nil)
          return unless job.is_a?(Hash)

          job_class = (job["wrapped"] || job[:wrapped] || job["class"] || job[:class]).to_s
          resolved_queue = (queue || job["queue"] || job[:queue]).to_s
          jid = (job["jid"] || job[:jid]).to_s
          retry_count = job.key?("retry_count") ? job["retry_count"] : job[:retry_count]

          ctx = {}
          ctx["queue"] = resolved_queue unless resolved_queue.empty?
          ctx["jid"] = jid unless jid.empty?
          ctx["class"] = job_class unless job_class.empty?
          ctx["retry_count"] = retry_count unless retry_count.nil?

          scope = Sentrace.current_scope
          scope.set_context("sidekiq", ctx) unless ctx.empty?
          scope.set_tag("queue", resolved_queue) unless resolved_queue.empty?
          scope.set_transaction_name(job_class) unless job_class.empty? || scope.transaction_name
        end

        private
          def register_lifecycle_hooks_once!(config)
            @hooked_configs ||= ObjectSpace::WeakMap.new
            return if @hooked_configs.key?(config)

            @hooked_configs[config] = true
            config.on(:quiet) { Sentrace.flush(timeout: 2.0) }
            config.on(:shutdown) { Sentrace.flush(timeout: 2.0) }
          rescue StandardError
            nil
          end
      end
    end
  end
end
