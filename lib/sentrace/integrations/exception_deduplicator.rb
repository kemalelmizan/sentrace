module Sentrace
  module Integrations
    module ExceptionDeduplicator
      @mutex = Mutex.new
      @captured = ObjectSpace::WeakMap.new

      class << self
        def already_captured?(exception)
          return false unless exception.is_a?(Exception)

          @mutex.synchronize { @captured.key?(exception) }
        rescue StandardError
          false
        end

        def mark_captured!(exception)
          return false unless exception.is_a?(Exception)

          @mutex.synchronize do
            return false if @captured.key?(exception)

            @captured[exception] = true
            true
          end
        rescue StandardError
          true
        end

        def capture_unhandled_once(exception, mechanism_type:, **options)
          return nil unless exception.is_a?(Exception)

          config = Sentrace.configuration
          return nil unless config.enabled && config.capture_unhandled_exceptions
          return nil if CaptureDispatcher.exception_excluded?(exception, config: config)
          return nil unless mark_captured!(exception)

          CaptureDispatcher.capture_exception(
            exception,
            handled: false,
            mechanism_type: mechanism_type,
            config: config,
            **options
          )
        end

        def reset!
          @mutex.synchronize { @captured = ObjectSpace::WeakMap.new }
        end
      end
    end
  end
end
