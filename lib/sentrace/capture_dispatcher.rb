module Sentrace
  class CaptureDispatcher
    REENTRANCY_KEY = :sentrace_in_dispatch

    @project_cache_mutex = Mutex.new
    @project_cache = {}

    class << self
      def capture_exception(exception, config: Sentrace.configuration, worker: AsyncWorker.default, **options)
        return nil unless exception.is_a?(Exception)
        return nil if Thread.current[REENTRANCY_KEY]
        return nil unless dispatchable?(config, explicit_project_id: options[:project_id])
        return nil unless sampled?(config)
        return nil if in_process_rate_limited?(config, explicit_project_id: options[:project_id])

        raw_event = EventBuilder.build_exception_event(
          exception,
          scope: Scope.current,
          config: config,
          **options
        )
        hint = { exception: exception, mechanism_type: options[:mechanism_type] || "generic" }

        dispatch_raw_event(
          raw_event,
          hint: hint,
          explicit_project_id: options[:project_id],
          config: config,
          worker: worker,
          apply_sampling: false,
          apply_before_send: true,
          rate_limit_checked: true
        )
      end

      def capture_message(message, level: :info, config: Sentrace.configuration, worker: AsyncWorker.default, **options)
        return nil if message.nil? || message.to_s.empty?
        return nil if Thread.current[REENTRANCY_KEY]
        return nil unless dispatchable?(config, explicit_project_id: options[:project_id])
        return nil unless sampled?(config)
        return nil if in_process_rate_limited?(config, explicit_project_id: options[:project_id])

        raw_event = EventBuilder.build_message_event(
          message,
          level: level,
          scope: Scope.current,
          config: config,
          **options
        )
        hint = { message: message.to_s }

        dispatch_raw_event(
          raw_event,
          hint: hint,
          explicit_project_id: options[:project_id],
          config: config,
          worker: worker,
          apply_sampling: false,
          apply_before_send: true,
          rate_limit_checked: true
        )
      end

      def dispatch_raw_event(
        raw_event,
        envelope_headers: {},
        hint: {},
        explicit_project_id: nil,
        received_at: Time.current,
        config: Sentrace.configuration,
        worker: AsyncWorker.default,
        apply_sampling: false,
        apply_before_send: false,
        rate_limit_checked: false
      )
        return nil unless raw_event.is_a?(Hash)
        return nil if Thread.current[REENTRANCY_KEY]
        return nil unless dispatchable?(config, explicit_project_id: explicit_project_id)
        return nil if apply_sampling && !sampled?(config)
        return nil if !rate_limit_checked && in_process_rate_limited?(config, explicit_project_id: explicit_project_id)

        prepared = EventBuilder.deep_stringify(raw_event)
        prepared["event_id"] = normalize_or_generate_event_id(prepared["event_id"], envelope_headers)

        if apply_before_send && config.before_send
          filtered = invoke_before_send(config.before_send, prepared, hint)
          return nil unless filtered.is_a?(Hash)

          prepared = EventBuilder.deep_stringify(filtered)
          prepared["event_id"] = normalize_or_generate_event_id(prepared["event_id"], envelope_headers)
        end

        event_id = prepared["event_id"]
        headers_snapshot = EventBuilder.deep_stringify(envelope_headers || {})

        if config.capture_dispatch == :inline
          persist_inline(
            prepared,
            envelope_headers: headers_snapshot,
            received_at: received_at,
            explicit_project_id: explicit_project_id,
            config: config,
            worker: worker
          ) ? event_id : nil
        else
          enqueued = worker.enqueue(queue_size: config.async_queue_size) do
            persist_on_current_connection(
              prepared,
              envelope_headers: headers_snapshot,
              received_at: received_at,
              explicit_project_id: explicit_project_id,
              config: config
            )
          end
          enqueued ? event_id : nil
        end
      end

      def resolve_project_id(config: Sentrace.configuration, explicit_project_id: nil)
        if explicit_project_id
          id_int = explicit_project_id.to_i
          return nil unless id_int.positive?

          return lookup_cached([ :explicit, id_int ]) { Project.where(id: id_int).pick(:id) }
        end

        if !config.project_id.nil? && !config.project_id.to_s.strip.empty?
          id_int = config.project_id.to_i
          return nil unless id_int.positive?

          return lookup_cached([ :id, id_int ]) { Project.where(id: id_int).pick(:id) }
        end

        slug = config.project_slug.to_s.strip
        return nil if slug.empty?

        lookup_cached([ :slug, slug ]) { Project.where(slug: slug).pick(:id) }
      end

      def clear_cache!
        @project_cache_mutex.synchronize { @project_cache.clear }
        FrontendDsnResolver.clear_cache! if defined?(FrontendDsnResolver)
      end

      def exception_excluded?(exception, config: Sentrace.configuration)
        return false unless exception.is_a?(Exception)

        Array(config.excluded_exceptions).any? do |pattern|
          case pattern
          when Module
            exception.is_a?(pattern)
          when String, Symbol
            target_name = pattern.to_s
            exception.class.ancestors.any? { |anc| anc.name == target_name }
          else
            false
          end
        end
      end

      private
        def dispatchable?(config, explicit_project_id:)
          return false unless config.enabled

          !explicit_project_id.nil? || config.target_project_configured?
        end

        def in_process_rate_limited?(config, explicit_project_id:)
          limit = config.respond_to?(:in_process_rate_limit_per_minute) ? config.in_process_rate_limit_per_minute : nil
          return false unless limit

          identifier = (explicit_project_id || config.project_id || config.project_slug || "default").to_s
          result = RateLimiter.check!(
            bucket: "in_process_capture",
            identifier: identifier,
            limit: limit
          )
          !result[:allowed]
        end

        def sampled?(config)
          rate = config.sample_rate.to_f
          return false if rate <= 0.0
          return true if rate >= 1.0

          Kernel.rand < rate
        end

        def invoke_before_send(callable, raw_event, hint)
          Thread.current[REENTRANCY_KEY] = true
          callable.call(raw_event, hint)
        ensure
          Thread.current[REENTRANCY_KEY] = false
        end

        def normalize_or_generate_event_id(candidate, envelope_headers)
          raw = (candidate || envelope_headers&.[]("event_id") || envelope_headers&.[](:event_id)).to_s.strip.delete("-").downcase
          raw.match?(Ingestion::EventNormalizer::EVENT_ID_HEX) ? raw : SecureRandom.hex(16)
        end

        def persist_inline(raw_event, envelope_headers:, received_at:, explicit_project_id:, config:, worker: AsyncWorker.default)
          if isolate_caller_connection?
            if connection_pool_saturated?
              return worker.enqueue(queue_size: config.async_queue_size) do
                persist_on_current_connection(
                  raw_event,
                  envelope_headers: envelope_headers,
                  received_at: received_at,
                  explicit_project_id: explicit_project_id,
                  config: config
                )
              end
            end

            Thread.new do
              Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)
              Thread.current[REENTRANCY_KEY] = true
              ActiveRecord::Base.connection_pool.with_connection do
                persist_on_current_connection(
                  raw_event,
                  envelope_headers: envelope_headers,
                  received_at: received_at,
                  explicit_project_id: explicit_project_id,
                  config: config
                )
              end
            end.value
          else
            Thread.current[REENTRANCY_KEY] = true
            begin
              persist_on_current_connection(
                raw_event,
                envelope_headers: envelope_headers,
                received_at: received_at,
                explicit_project_id: explicit_project_id,
                config: config
              )
            ensure
              Thread.current[REENTRANCY_KEY] = false
            end
          end
        rescue StandardError, ScriptError => e
          log_warning("[Sentrace] Inline capture failed (#{e.class}): #{e.message}")
          false
        end

        def persist_on_current_connection(raw_event, envelope_headers:, received_at:, explicit_project_id:, config:)
          project_id = resolve_project_id(config: config, explicit_project_id: explicit_project_id)
          unless project_id
            log_warning("[Sentrace] Target project not found for capture (project_id=#{config.project_id.inspect}, project_slug=#{config.project_slug.inspect})")
            return false
          end

          Ingestion::Processor.ingest_event(
            raw_event,
            project: project_id,
            envelope_headers: envelope_headers,
            received_at: received_at,
            config: config,
            ingestion_source: "in_process"
          )
          true
        end

        def isolate_caller_connection?
          return false unless ActiveRecord::Base.connection_pool.active_connection?

          conn = ActiveRecord::Base.connection
          return true if pg_connection_in_error?(conn)
          return false unless conn.transaction_open?

          # Rails transactional test fixtures open a non-joinable outer transaction (`joinable? == false`).
          # Application `ActiveRecord::Base.transaction` blocks always have `joinable? == true`.
          conn.current_transaction.joinable?
        rescue StandardError
          true
        end

        def pg_connection_in_error?(conn)
          raw = conn.raw_connection
          defined?(PG::PQTRANS_INERROR) &&
            raw.respond_to?(:transaction_status) &&
            raw.transaction_status == PG::PQTRANS_INERROR
        rescue StandardError
          false
        end

        def connection_pool_saturated?
          pool = ActiveRecord::Base.connection_pool
          return false unless pool.respond_to?(:stat)

          stats = pool.stat
          size = stats[:size].to_i
          busy = stats[:busy].to_i
          size.positive? && busy >= size
        rescue StandardError
          false
        end

        def lookup_cached(cache_key)
          cached = @project_cache_mutex.synchronize { @project_cache[cache_key] }
          return cached if cached

          resolved = yield
          if resolved
            @project_cache_mutex.synchronize { @project_cache[cache_key] = resolved }
          end
          resolved
        end

        def log_warning(message)
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.warn(message)
          else
            warn(message)
          end
        rescue StandardError
          nil
        end
    end
  end
end
