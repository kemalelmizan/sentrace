require "time"

module Sentrace
  class StorageStats
    ENGINE_TABLES = %w[
      sentrace_projects
      sentrace_project_keys
      sentrace_mcp_tokens
      sentrace_issues
      sentrace_events
    ].freeze

    class << self
      def collect(days: 30, now: Time.current)
        new.collect(days: days, now: now)
      end

      def print_report(io: $stdout, days: 30)
        stats = collect(days: days)
        io.puts "Sentrace PostgreSQL Storage Statistics:"
        io.puts "  Total events:                #{stats["total_events"]}"
        io.puts "  Total issues:                #{stats["total_issues"]}"
        io.puts "  Events removed by retention: #{stats["events_removed_by_retention"]}"
        io.puts "  Oldest retained event:       #{stats["oldest_retained_event_at"] || "(none)"}"
        io.puts "  Newest retained event:       #{stats["newest_retained_event_at"] || "(none)"}"
        io.puts "  Total storage bytes:         #{stats["database_storage_bytes"]} (tables: #{stats["table_bytes"]}, indexes: #{stats["index_bytes"]})"
        stats
      end
    end

    def collect(days: 30, now: Time.current)
      conn = ActiveRecord::Base.connection

      event_row = conn.select_one(<<~SQL.squish) || {}
        SELECT COUNT(*) AS total_events,
               MIN(occurred_at) AS oldest_at,
               MAX(occurred_at) AS newest_at
        FROM sentrace_events
      SQL

      issue_row = conn.select_one(<<~SQL.squish) || {}
        SELECT COUNT(*) AS total_issues,
               COALESCE(SUM(event_count), 0) AS cumulative_issue_events
        FROM sentrace_issues
      SQL

      pg_stat_row = conn.select_one(<<~SQL.squish) || {}
        SELECT COALESCE(n_tup_del, 0) AS deleted_tuples
        FROM pg_stat_user_tables
        WHERE schemaname = current_schema()
          AND relname = 'sentrace_events'
      SQL

      total_events = event_row["total_events"].to_i
      total_issues = issue_row["total_issues"].to_i
      cumulative_issue_events = issue_row["cumulative_issue_events"].to_i
      removed_by_retention = [ cumulative_issue_events - total_events, 0 ].max

      tables_breakdown = fetch_table_sizes(conn)
      daily_counts = fetch_events_per_day(conn, days: days, now: now)

      {
        "total_events" => total_events,
        "total_issues" => total_issues,
        "events_removed_by_retention" => removed_by_retention,
        "pg_stat_events_deleted_tuples" => pg_stat_row["deleted_tuples"].to_i,
        "oldest_retained_event_at" => format_optional_utc(event_row["oldest_at"]),
        "newest_retained_event_at" => format_optional_utc(event_row["newest_at"]),
        "database_storage_bytes" => tables_breakdown.sum { |t| t["total_bytes"] },
        "table_bytes" => tables_breakdown.sum { |t| t["table_bytes"] },
        "index_bytes" => tables_breakdown.sum { |t| t["index_bytes"] },
        "tables" => tables_breakdown,
        "events_per_day" => daily_counts
      }
    end

    private
      def fetch_table_sizes(conn)
        quoted_names = ENGINE_TABLES.map { |name| conn.quote(name) }.join(", ")
        rows = conn.select_all(<<~SQL.squish).to_a
          SELECT c.relname AS table_name,
                 pg_table_size(c.oid) AS table_bytes,
                 pg_indexes_size(c.oid) AS index_bytes,
                 pg_total_relation_size(c.oid) AS total_bytes
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = current_schema()
            AND c.relname IN (#{quoted_names})
          ORDER BY c.relname ASC
        SQL

        rows.map do |row|
          {
            "table_name" => row["table_name"],
            "table_bytes" => row["table_bytes"].to_i,
            "index_bytes" => row["index_bytes"].to_i,
            "total_bytes" => row["total_bytes"].to_i
          }
        end
      end

      def fetch_events_per_day(conn, days:, now:)
        window_days = [ days.to_i, 1 ].max
        cutoff = now.utc - window_days.days
        sql = Event.sanitize_sql_array([
          <<~SQL.squish,
            SELECT DATE_TRUNC('day', occurred_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS day_bucket,
                   COUNT(*) AS event_count
            FROM sentrace_events
            WHERE occurred_at >= ?
            GROUP BY 1
            ORDER BY 1 DESC
          SQL
          cutoff
        ])

        conn.select_all(sql).to_a.map do |row|
          bucket_time = parse_utc(row["day_bucket"])
          {
            "date" => bucket_time.strftime("%Y-%m-%d"),
            "count" => row["event_count"].to_i
          }
        end
      end

      def format_optional_utc(value)
        return nil if value.nil?

        parse_utc(value).iso8601
      end

      def parse_utc(value)
        value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
      end
  end
end
