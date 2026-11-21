module Sentrace
  module Retention
    class Cleaner
      CleanupResult = Data.define(
        :deleted_events_count,
        :deleted_orphan_issues_count,
        :event_batches,
        :issue_batches,
        :event_cutoff,
        :orphan_issue_cutoff
      )

      class << self
        def run!(now: Time.current, config: Sentrace.configuration)
          new(config: config).run!(now: now)
        end
      end

      def initialize(config: Sentrace.configuration)
        @config = config
      end

      def run!(now: Time.current)
        reference_time = now.utc
        batch_size = @config.retention_batch_size
        event_cutoff = reference_time - @config.retention_period
        orphan_issue_cutoff = reference_time - @config.orphan_issue_retention_period

        deleted_events, event_batches = delete_expired_events_in_batches(event_cutoff, batch_size)
        deleted_issues, issue_batches = delete_orphan_issues_in_batches(orphan_issue_cutoff, batch_size)

        CleanupResult.new(
          deleted_events_count: deleted_events,
          deleted_orphan_issues_count: deleted_issues,
          event_batches: event_batches,
          issue_batches: issue_batches,
          event_cutoff: event_cutoff,
          orphan_issue_cutoff: orphan_issue_cutoff
        )
      end

      private
        def delete_expired_events_in_batches(cutoff, batch_size)
          total_deleted = 0
          batches = 0

          loop do
            sql = Event.sanitize_sql_array([
              <<~SQL.squish,
                DELETE FROM sentrace_events
                WHERE id IN (
                  SELECT id FROM (
                    (
                      SELECT id FROM sentrace_events
                      WHERE received_at < ?
                      ORDER BY received_at ASC
                      LIMIT ?
                    )
                    UNION
                    (
                      SELECT id FROM sentrace_events
                      WHERE occurred_at < ?
                      ORDER BY occurred_at ASC
                      LIMIT ?
                    )
                  ) AS expired_events
                  LIMIT ?
                )
              SQL
              cutoff,
              batch_size,
              cutoff,
              batch_size,
              batch_size
            ])

            deleted = Event.connection.delete(sql)
            break if deleted.zero?

            total_deleted += deleted
            batches += 1
          end

          [ total_deleted, batches ]
        end

        def delete_orphan_issues_in_batches(orphan_cutoff, batch_size)
          total_deleted = 0
          batches = 0

          loop do
            sql = Issue.sanitize_sql_array([
              <<~SQL.squish,
                DELETE FROM sentrace_issues
                WHERE id IN (
                  SELECT i.id FROM sentrace_issues i
                  WHERE i.last_seen_at < ?
                    AND NOT EXISTS (
                      SELECT 1 FROM sentrace_events e WHERE e.issue_id = i.id
                    )
                  ORDER BY i.last_seen_at ASC
                  LIMIT ?
                )
              SQL
              orphan_cutoff,
              batch_size
            ])

            deleted = Issue.connection.delete(sql)
            break if deleted.zero?

            total_deleted += deleted
            batches += 1
          end

          [ total_deleted, batches ]
        end
    end
  end
end
