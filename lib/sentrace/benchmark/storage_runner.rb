require "json"
require "securerandom"

module Sentrace
  module Benchmark
    class StorageRunner
      DEFAULT_EVENT_COUNT = 500
      DISTINCT_ISSUE_COUNT = 25

      EXCEPTION_CLASSES = %w[
        ActiveRecord::RecordNotFound
        Stripe::CardError
        Redis::TimeoutError
        NoMethodError
        ActionController::ParameterMissing
      ].freeze

      class << self
        def run(event_count: DEFAULT_EVENT_COUNT, batch_size: 250, cleanup: true)
          new(event_count: event_count, batch_size: batch_size, cleanup: cleanup).run
        end

        def print_report(event_count: DEFAULT_EVENT_COUNT, batch_size: 250, io: $stdout)
          report = run(event_count: event_count, batch_size: batch_size, cleanup: true)
          io.puts "=== Sentrace PostgreSQL Storage & Performance Benchmark ==="
          io.puts "Events generated:               #{report["event_count"]} (#{report["distinct_issues"]} distinct issues)"
          io.puts "DB size before ingestion:       #{report["db_bytes_before"]} bytes"
          io.puts "DB size after ingestion:        #{report["db_bytes_after"]} bytes (delta: +#{report["net_storage_delta_bytes"]} bytes)"
          io.puts "Avg PostgreSQL bytes / event:   #{report["avg_bytes_per_event"]} bytes"
          io.puts "Index overhead (after):         #{report["index_overhead_bytes"]} bytes (#{report["index_overhead_pct"]}%)"
          io.puts "Envelope parse latency (avg):   #{report["envelope_parse_ms"]} ms (target < 50 ms)"
          io.puts "Event persist latency (avg):    #{report["event_persist_avg_ms"]} ms (target < 100 ms)"
          io.puts "Write throughput:               #{report["write_events_per_second"]} events/sec"
          io.puts "Issue lookup latency:           #{report["issue_lookup_ms"]} ms (target < 100 ms)"
          io.puts "Event retrieval latency:        #{report["event_retrieval_ms"]} ms (target < 100 ms)"
          io.puts "MCP list_issues latency:        #{report["mcp_list_issues_ms"]} ms (target < 500 ms)"
          io.puts "Retention delete throughput:    #{report["retention_delete_events_per_second"]} events/sec (#{report["retention_deleted_events"]} pruned)"
          report
        end
      end

      def initialize(event_count: DEFAULT_EVENT_COUNT, batch_size: 250, cleanup: true)
        @event_count = [ event_count.to_i, 1 ].max
        @batch_size = [ batch_size.to_i, 1 ].max
        @cleanup = cleanup
      end

      def run
        slug = "bench-#{SecureRandom.hex(6)}"
        project, key = Project.provision!(slug: slug, name: "Sentrace Storage Benchmark")
        dsn = Dsn.build(base_url: "http://localhost:3000/sentrace", public_key: key.public_key, project_id: project.id).to_s

        vacuum_sentrace_tables_if_allowed!
        before_stats = StorageStats.collect

        envelopes = Array.new(@event_count) { |idx| build_representative_envelope(idx, dsn: dsn) }

        # 1. Measure envelope parsing latency
        parse_samples = envelopes.first([ 25, envelopes.size ].min)
        parse_started = monotonic_now
        parse_samples.each { |raw| Ingestion::EnvelopeParser.parse(raw) }
        envelope_parse_ms = (((monotonic_now - parse_started) / parse_samples.size) * 1_000.0).round(3)

        # 2. Measure ingestion + PostgreSQL persistence throughput & latency
        bench_config = Sentrace.configuration.dup
        bench_config.retention_period = 30.days
        bench_config.retention_batch_size = @batch_size

        ingest_started = monotonic_now
        bench_received_at = 42.days.ago.utc
        envelopes.each do |raw|
          Ingestion::Processor.process_raw_envelope(
            raw,
            project: project.id,
            received_at: bench_received_at,
            config: bench_config
          )
        end
        ingest_elapsed = [ monotonic_now - ingest_started, 0.000_001 ].max
        event_persist_avg_ms = ((ingest_elapsed / @event_count) * 1_000.0).round(3)
        write_eps = (@event_count / ingest_elapsed).round(1)

        vacuum_sentrace_tables_if_allowed!
        after_stats = StorageStats.collect
        distinct_issues_count = project.issues.count

        sample_issue = project.issues.order(last_seen_at: :desc).first
        sample_event = project.events.order(occurred_at: :desc).first
        backend = Mcp::LocalBackend.new(environment_name: "local")

        # 3. Measure query & MCP latencies
        t0 = monotonic_now
        backend.get_issue(issue_id: sample_issue.id, project_id: project.id)
        issue_lookup_ms = ((monotonic_now - t0) * 1_000.0).round(3)

        t1 = monotonic_now
        backend.get_event(event_id: sample_event.event_id.strip, project_id: project.id)
        event_retrieval_ms = ((monotonic_now - t1) * 1_000.0).round(3)

        mcp_server = Mcp::Server.build(dispatcher: Mcp::Dispatcher.new(config: bench_config, remote_client: nil))
        rpc_req = JSON.generate(
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name: "list_issues", arguments: { project_id: project.id, limit: 25 } }
        )
        t2 = monotonic_now
        mcp_server.handle_json(rpc_req)
        mcp_list_issues_ms = ((monotonic_now - t2) * 1_000.0).round(3)

        # 4. Measure batch retention deletion throughput
        t3 = monotonic_now
        cleanup_res = Retention::Cleaner.run!(config: bench_config)
        retention_elapsed = [ monotonic_now - t3, 0.000_001 ].max
        retention_eps = (cleanup_res.deleted_events_count / retention_elapsed).round(1)

        compute_report(
          before_stats: before_stats,
          after_stats: after_stats,
          distinct_issues: distinct_issues_count,
          envelope_parse_ms: envelope_parse_ms,
          event_persist_avg_ms: event_persist_avg_ms,
          write_eps: write_eps,
          issue_lookup_ms: issue_lookup_ms,
          event_retrieval_ms: event_retrieval_ms,
          mcp_list_issues_ms: mcp_list_issues_ms,
          deleted_events: cleanup_res.deleted_events_count,
          retention_eps: retention_eps
        )
      ensure
        project&.destroy if @cleanup
      end

      private
        def compute_report(
          before_stats:,
          after_stats:,
          distinct_issues:,
          envelope_parse_ms:,
          event_persist_avg_ms:,
          write_eps:,
          issue_lookup_ms:,
          event_retrieval_ms:,
          mcp_list_issues_ms:,
          deleted_events:,
          retention_eps:
        )
          db_before = before_stats["database_storage_bytes"]
          db_after = after_stats["database_storage_bytes"]
          net_delta = [ db_after - db_before, 0 ].max

          events_rel_after = after_stats["tables"].find { |t| t["table_name"] == "sentrace_events" } || {}
          events_rel_before = before_stats["tables"].find { |t| t["table_name"] == "sentrace_events" } || {}
          events_delta = [ events_rel_after["total_bytes"].to_i - events_rel_before["total_bytes"].to_i, 0 ].max

          avg_bytes =
            if events_delta.positive?
              (events_delta.to_f / @event_count).round(2)
            else
              total_after = [ after_stats["total_events"].to_i, 1 ].max
              (events_rel_after["total_bytes"].to_f / total_after).round(2)
            end

          idx_bytes = after_stats["index_bytes"]
          total_bytes = [ db_after, 1 ].max
          idx_pct = ((idx_bytes.to_f / total_bytes) * 100.0).round(2)

          {
            "event_count" => @event_count,
            "distinct_issues" => distinct_issues,
            "db_bytes_before" => db_before,
            "db_bytes_after" => db_after,
            "net_storage_delta_bytes" => net_delta,
            "avg_bytes_per_event" => avg_bytes,
            "index_overhead_bytes" => idx_bytes,
            "index_overhead_pct" => idx_pct,
            "envelope_parse_ms" => envelope_parse_ms,
            "event_persist_avg_ms" => event_persist_avg_ms,
            "write_events_per_second" => write_eps,
            "issue_lookup_ms" => issue_lookup_ms,
            "event_retrieval_ms" => event_retrieval_ms,
            "mcp_list_issues_ms" => mcp_list_issues_ms,
            "retention_deleted_events" => deleted_events,
            "retention_delete_events_per_second" => retention_eps
          }
        end

        def build_representative_envelope(index, dsn:)
          issue_bucket = index % DISTINCT_ISSUE_COUNT
          exc_class = EXCEPTION_CLASSES[issue_bucket % EXCEPTION_CLASSES.size]
          event_id = format("%032x", index + 1)
          occurred_at = (42.days.ago.utc + index.seconds).iso8601

          envelope_header = JSON.generate(
            event_id: event_id,
            dsn: dsn,
            sent_at: occurred_at
          )
          item_header = JSON.generate(type: "event")
          payload = JSON.generate(
            event_id: event_id,
            timestamp: occurred_at,
            platform: "ruby",
            level: "error",
            environment: "production",
            release: "2026.11.#{issue_bucket % 4}",
            server_name: "web-#{(index % 4) + 1}",
            exception: {
              values: [
                {
                  type: exc_class,
                  value: "#{exc_class} in workflow bucket ##{issue_bucket} for request #{index}",
                  stacktrace: {
                    frames: build_frames(issue_bucket)
                  }
                }
              ]
            },
            request: {
              url: "https://app.example.com/api/v1/orders/#{index}?page=1",
              method: "POST",
              headers: { "User-Agent" => "SentraceBenchmark/1.0", "Accept" => "application/json" }
            },
            breadcrumbs: {
              values: Array.new(8) do |b_idx|
                {
                  timestamp: occurred_at,
                  category: b_idx.even? ? "sql.active_record" : "http.client",
                  level: "info",
                  message: "Executed step #{b_idx} during checkout pipeline"
                }
              end
            },
            tags: {
              "service" => "checkout",
              "region" => "us-east-1",
              "queue" => "critical",
              "bucket" => "b#{issue_bucket}"
            },
            contexts: {
              "runtime" => { "name" => "ruby", "version" => RUBY_VERSION },
              "os" => { "name" => "Linux" }
            },
            user: {
              "id" => "usr_#{(index % 50) + 1}",
              "email" => "redacted@example.com"
            }
          )

          "#{envelope_header}\n#{item_header}\n#{payload}\n"
        end

        def build_frames(issue_bucket)
          framework_frames = Array.new(6) do |idx|
            {
              filename: "gems/actionpack-8.1.4/lib/action_dispatch/middleware/stack_#{idx}.rb",
              function: "call",
              lineno: 40 + idx,
              in_app: false
            }
          end

          app_frames = [
            {
              filename: "app/controllers/orders_controller.rb",
              function: "create",
              lineno: 18,
              in_app: true
            },
            {
              filename: "app/services/order_processor_#{issue_bucket}.rb",
              function: "execute!",
              lineno: 52 + issue_bucket,
              in_app: true
            }
          ]

          framework_frames + app_frames
        end

        def vacuum_sentrace_tables_if_allowed!
          conn = ActiveRecord::Base.connection
          return unless conn.open_transactions.zero?

          StorageStats::ENGINE_TABLES.each do |table|
            conn.execute("VACUUM ANALYZE #{conn.quote_table_name(table)}")
          end
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
    end
  end
end
