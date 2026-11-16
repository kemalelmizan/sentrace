module Sentrace
  class AsyncWorker
    SHUTDOWN_SENTINEL = Object.new.freeze

    class << self
      def default
        @default ||= new
      end

      def reset_default!(timeout: 1.0)
        @default&.shutdown(timeout: timeout)
        @default = new
      end
    end

    def initialize
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @pid = nil
      @queue = nil
      @queue_capacity = nil
      @worker_thread = nil
      @pending = 0
      @paused = false
    end

    def enqueue(job = nil, queue_size: Sentrace.configuration.async_queue_size, &block)
      work = job || block
      raise ArgumentError, "enqueue requires a callable or block" unless work.respond_to?(:call)

      capacity = queue_size.is_a?(Integer) && queue_size.positive? ? queue_size : 256
      enqueued = false

      @mutex.synchronize do
        ensure_worker_locked!(capacity)
        begin
          @queue.push(work, true)
          @pending += 1
          enqueued = true
        rescue ThreadError
          enqueued = false
        end
      end

      warn_queue_overflow(capacity) unless enqueued
      enqueued
    end

    def flush(timeout: 2.0)
      deadline = monotonic_now + timeout.to_f

      @mutex.synchronize do
        return true if @pid != Process.pid || @queue.nil?

        ensure_worker_locked!(@queue_capacity || 256) if @pending.positive?

        until @pending.zero?
          remaining = deadline - monotonic_now
          return false if remaining <= 0

          @cond.wait(@mutex, remaining)
        end
        true
      end
    end

    def shutdown(timeout: 2.0)
      flush(timeout: timeout)
      thread_to_join = nil

      @mutex.synchronize do
        @paused = false
        @cond.broadcast
        if @pid == Process.pid && @worker_thread&.alive? && @queue
          begin
            @queue.push(SHUTDOWN_SENTINEL, true)
          rescue ThreadError
            # Queue full; worker exits once pid/thread resets
          end
          thread_to_join = @worker_thread
        end
        @worker_thread = nil
        @queue = nil
        @pid = nil
        @pending = 0
      end

      thread_to_join&.join(timeout)
      true
    end

    def worker_pid
      @mutex.synchronize { @pid }
    end

    def worker_alive?
      @mutex.synchronize { @pid == Process.pid && @worker_thread&.alive? == true }
    end

    # Used by specs to deterministically fill the bounded SizedQueue and test overflow behavior
    def pause_processing!
      @mutex.synchronize { @paused = true }
    end

    def resume_processing!
      @mutex.synchronize do
        @paused = false
        @cond.broadcast
      end
    end

    private
      def ensure_worker_locked!(capacity)
        current_pid = Process.pid

        if @pid != current_pid
          # Forked child (e.g. Puma `preload_app!` or Unicorn): discard inherited parent queue/thread
          @pid = current_pid
          @queue_capacity = capacity
          @queue = SizedQueue.new(capacity)
          @pending = 0
          @paused = false
          @worker_thread = spawn_worker_thread(@queue, current_pid)
        elsif @queue.nil? || (@queue_capacity != capacity && @pending.zero?)
          @queue_capacity = capacity
          @queue = SizedQueue.new(capacity)
          @worker_thread = spawn_worker_thread(@queue, current_pid) unless @worker_thread&.alive?
        elsif !@worker_thread&.alive?
          @worker_thread = spawn_worker_thread(@queue, current_pid)
        end
      end

      def spawn_worker_thread(queue, owner_pid)
        Thread.new do
          Thread.current.name = "sentrace-async-worker" if Thread.current.respond_to?(:name=)
          Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)

          loop do
            job = queue.pop
            break if job.equal?(SHUTDOWN_SENTINEL) || Process.pid != owner_pid

            @mutex.synchronize do
              @cond.wait(@mutex, 0.05) while @paused && Process.pid == owner_pid
            end

            begin
              Thread.current[:sentrace_in_dispatch] = true
              ActiveRecord::Base.connection_pool.with_connection do
                job.call
              end
            rescue StandardError, ScriptError => e
              log_warning("[Sentrace] Async capture worker failed (#{e.class}): #{e.message}")
            ensure
              Thread.current[:sentrace_in_dispatch] = false
              @mutex.synchronize do
                @pending -= 1 if @pending.positive?
                @cond.broadcast
              end
            end
          end
        end
      end

      def warn_queue_overflow(capacity)
        log_warning("[Sentrace] Dropping captured event because async_queue_size (#{capacity}) is full")
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

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
  end
end

at_exit do
  Sentrace.flush(timeout: 2.0) if defined?(Sentrace) && Sentrace.respond_to?(:flush)
rescue StandardError
  nil
end
