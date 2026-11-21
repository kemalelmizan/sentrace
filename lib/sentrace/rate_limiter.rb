require "openssl"

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
      def check!(bucket:, identifier:, limit:, increment: true, cost: 1)
        return { allowed: true, count: 0, limit: nil, retry_after: 0 } if limit.nil?

        effective_cost = [ cost.to_i, 1 ].max
        now = Time.current.to_i
        window_id = now / WINDOW_SECONDS
        retry_after = [ WINDOW_SECONDS - (now % WINDOW_SECONDS), 1 ].max
        bucket_name = bucket.to_s
        id_digest = OpenSSL::Digest::SHA256.hexdigest(identifier.to_s)[0, 32]
        cache_key = "sentrace:rate_limit:#{bucket_name}:#{window_id}:#{id_digest}"

        count =
          if increment
            increment_counter(bucket_name, cache_key, limit: limit, amount: effective_cost)
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

        def increment_counter(bucket_name, cache_key, limit:, amount: 1)
          store = cache_store
          if store
            count = store.increment(cache_key, amount, expires_in: WINDOW_SECONDS.seconds, raw: true)
            if count.nil?
              written = store.write(cache_key, amount, expires_in: WINDOW_SECONDS.seconds, raw: true, unless_exist: true)
              count = written ? amount : (store.increment(cache_key, amount, expires_in: WINDOW_SECONDS.seconds, raw: true) || amount)
            end
            count.to_i
          else
            increment_memory_counter(bucket_name, cache_key, limit: limit, amount: amount)
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

        def increment_memory_counter(bucket_name, cache_key, limit:, amount: 1)
          now = Time.current.to_i
          @memory_mutex.synchronize do
            bucket_store = fetch_or_create_bucket_locked!(bucket_name)
            prune_expired_bucket_entries!(bucket_name, bucket_store, now)
            entry = bucket_store[cache_key]
            if entry && entry[:expires_at] > now
              entry[:count] += amount
              entry[:count]
            else
              bucket_store.delete(cache_key) if entry
              if bucket_store.size >= MAX_MEMORY_ENTRIES_PER_BUCKET
                unless evict_entry_from_bucket!(bucket_store, limit: limit)
                  return [ limit + 1, amount ].max
                end
              end
              bucket_store[cache_key] = { count: amount, expires_at: now + WINDOW_SECONDS }
              amount
            end
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
            protected_buckets = %w[mcp_auth_fail mcp internal ingestion_ip ingestion_project in_process_capture]
            evictable_bucket = @memory_store.keys.find { |k| !protected_buckets.include?(k) }
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
          # Never evict entries that have reached or exceeded `limit` so active lockouts cannot be flushed
          candidate_key = nil
          candidate_count = nil
          bucket_store.each do |key, entry|
            next if entry[:count] >= limit
            if candidate_count.nil? || entry[:count] < candidate_count
              candidate_key = key
              candidate_count = entry[:count]
              break if candidate_count <= 1
            end
          end
          return false unless candidate_key

          bucket_store.delete(candidate_key)
          true
        end
    end
  end
end
