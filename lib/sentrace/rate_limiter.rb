module Sentrace
  module RateLimiter
    WINDOW_SECONDS = 60

    @memory_mutex = Mutex.new
    @memory_store = {}

    class << self
      def check!(bucket:, identifier:, limit:, increment: true)
        return { allowed: true, count: 0, limit: nil, retry_after: 0 } if limit.nil?

        now = Time.current.to_i
        window_id = now / WINDOW_SECONDS
        retry_after = [ WINDOW_SECONDS - (now % WINDOW_SECONDS), 1 ].max
        cache_key = "sentrace:rate_limit:#{bucket}:#{identifier}:#{window_id}"

        count =
          if increment
            increment_counter(cache_key)
          else
            read_counter(cache_key)
          end

        {
          allowed: count <= limit,
          count: count,
          limit: limit,
          retry_after: retry_after
        }
      end

      def reset!
        @memory_mutex.synchronize { @memory_store.clear }
      end

      private
        def cache_store
          return nil unless defined?(Rails) && Rails.respond_to?(:cache)

          store = Rails.cache
          return nil if store.nil? || store.class.name == "ActiveSupport::Cache::NullStore"

          store
        end

        def increment_counter(cache_key)
          store = cache_store
          if store
            count = store.increment(cache_key, 1, expires_in: WINDOW_SECONDS.seconds, raw: true)
            if count.nil?
              written = store.write(cache_key, 1, expires_in: WINDOW_SECONDS.seconds, raw: true, unless_exist: true)
              count = written ? 1 : (store.increment(cache_key, 1, expires_in: WINDOW_SECONDS.seconds, raw: true) || 1)
            end
            count.to_i
          else
            increment_memory_counter(cache_key)
          end
        end

        def read_counter(cache_key)
          store = cache_store
          if store
            store.read(cache_key, raw: true).to_i
          else
            read_memory_counter(cache_key)
          end
        end

        def increment_memory_counter(cache_key)
          now = Time.current.to_i
          @memory_mutex.synchronize do
            prune_expired_memory_entries!(now)
            entry = @memory_store[cache_key]
            if entry && entry[:expires_at] > now
              entry[:count] += 1
            else
              @memory_store[cache_key] = { count: 1, expires_at: now + WINDOW_SECONDS }
            end
            @memory_store[cache_key][:count]
          end
        end

        def read_memory_counter(cache_key)
          now = Time.current.to_i
          @memory_mutex.synchronize do
            entry = @memory_store[cache_key]
            return 0 unless entry && entry[:expires_at] > now

            entry[:count]
          end
        end

        def prune_expired_memory_entries!(now)
          return if @memory_store.size < 1024

          @memory_store.delete_if { |_k, entry| entry[:expires_at] <= now }
        end
    end
  end
end
