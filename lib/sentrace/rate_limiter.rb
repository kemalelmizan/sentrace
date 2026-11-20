module Sentrace
  module RateLimiter
    WINDOW_SECONDS = 60
    MAX_MEMORY_ENTRIES = 4_096
    MAX_MEMORY_ENTRIES_PER_BUCKET = 1_024
    MAX_MEMORY_BUCKETS = 32
    PRUNE_INTERVAL_SECONDS = 5

    @memory_mutex = Mutex.new
    @memory_store = {}
    @last_pruned_at = {}

    class << self
      def check!(bucket:, identifier:, limit:, increment: true)
        return { allowed: true, count: 0, limit: nil, retry_after: 0 } if limit.nil?

        now = Time.current.to_i
        window_id = now / WINDOW_SECONDS
        retry_after = [ WINDOW_SECONDS - (now % WINDOW_SECONDS), 1 ].max
        bucket_name = bucket.to_s
        cache_key = "sentrace:rate_limit:#{bucket_name}:#{identifier}:#{window_id}"

        count =
          if increment
            increment_counter(bucket_name, cache_key, limit: limit)
          else
            read_counter(bucket_name, cache_key)
          end

        {
          allowed: count <= limit,
          count: count,
          limit: limit,
          retry_after: retry_after
        }
      end

      def reset!
        @memory_mutex.synchronize do
          @memory_store.clear
          @last_pruned_at.clear
        end
      end

      def memory_entry_count(bucket = nil)
        @memory_mutex.synchronize do
          if bucket
            (@memory_store[bucket.to_s] || {}).size
          else
            @memory_store.values.sum(&:size)
          end
        end
      end

      private
        def cache_store
          return nil unless defined?(Rails) && Rails.respond_to?(:cache)

          store = Rails.cache
          return nil if store.nil? || store.class.name == "ActiveSupport::Cache::NullStore"

          store
        end

        def increment_counter(bucket_name, cache_key, limit:)
          store = cache_store
          if store
            count = store.increment(cache_key, 1, expires_in: WINDOW_SECONDS.seconds, raw: true)
            if count.nil?
              written = store.write(cache_key, 1, expires_in: WINDOW_SECONDS.seconds, raw: true, unless_exist: true)
              count = written ? 1 : (store.increment(cache_key, 1, expires_in: WINDOW_SECONDS.seconds, raw: true) || 1)
            end
            count.to_i
          else
            increment_memory_counter(bucket_name, cache_key, limit: limit)
          end
        end

        def read_counter(bucket_name, cache_key)
          store = cache_store
          if store
            store.read(cache_key, raw: true).to_i
          else
            read_memory_counter(bucket_name, cache_key)
          end
        end

        def increment_memory_counter(bucket_name, cache_key, limit:)
          now = Time.current.to_i
          @memory_mutex.synchronize do
            bucket_store = fetch_or_create_bucket_locked!(bucket_name)
            prune_expired_bucket_entries!(bucket_name, bucket_store, now)
            entry = bucket_store[cache_key]
            if entry && entry[:expires_at] > now
              entry[:count] += 1
            else
              if bucket_store.size >= MAX_MEMORY_ENTRIES_PER_BUCKET && !bucket_store.key?(cache_key)
                evict_entry_from_bucket!(bucket_store, limit: limit)
              end
              bucket_store[cache_key] = { count: 1, expires_at: now + WINDOW_SECONDS }
            end
            bucket_store[cache_key][:count]
          end
        end

        def read_memory_counter(bucket_name, cache_key)
          now = Time.current.to_i
          @memory_mutex.synchronize do
            bucket_store = @memory_store[bucket_name]
            return 0 unless bucket_store

            entry = bucket_store[cache_key]
            return 0 unless entry && entry[:expires_at] > now

            entry[:count]
          end
        end

        def fetch_or_create_bucket_locked!(bucket_name)
          existing = @memory_store[bucket_name]
          return existing if existing

          if @memory_store.size >= MAX_MEMORY_BUCKETS
            evictable_bucket = @memory_store.keys.find { |k| k != "mcp_auth_fail" && k != "mcp" && k != "internal" }
            @memory_store.delete(evictable_bucket) if evictable_bucket
          end

          @memory_store[bucket_name] = {}
        end

        def prune_expired_bucket_entries!(bucket_name, bucket_store, now)
          return if bucket_store.size < 256
          last_pruned = @last_pruned_at[bucket_name] || 0
          return if (now - last_pruned) < PRUNE_INTERVAL_SECONDS && bucket_store.size < MAX_MEMORY_ENTRIES_PER_BUCKET

          @last_pruned_at[bucket_name] = now
          bucket_store.delete_if { |_k, entry| entry[:expires_at] <= now }
        end

        def evict_entry_from_bucket!(bucket_store, limit:)
          # Prefer evicting the lowest-count (non-throttled) entry so active lockouts are preserved
          candidate_key, _entry = bucket_store.min_by { |_k, entry| [ entry[:count] >= limit ? 1 : 0, entry[:count] ] }
          bucket_store.delete(candidate_key) if candidate_key
        end
    end
  end
end
