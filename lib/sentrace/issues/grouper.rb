require "json"

module Sentrace
  module Issues
    class Grouper
      PersistResult = Data.define(:event_id, :event_record_id, :issue_id, :duplicate)

      class << self
        def persist!(project_id:, normalized_event:, fingerprint:)
          new.persist!(
            project_id: project_id,
            normalized_event: normalized_event,
            fingerprint: fingerprint
          )
        end
      end

      def persist!(project_id:, normalized_event:, fingerprint:)
        level_int = Issue::LEVELS.fetch(normalized_event.level.to_sym, Issue::LEVELS[:error])
        now = Time.current.utc
        occurred_at = normalized_event.occurred_at.utc
        received_at = normalized_event.received_at.utc

        Issue.transaction do
          conn = Issue.connection

          issue_id = upsert_issue_shell(
            conn: conn,
            project_id: project_id,
            fingerprint: fingerprint,
            level_int: level_int,
            exception_type: normalized_event.exception_type,
            message: normalized_event.issue_message,
            occurred_at: occurred_at,
            now: now
          )

          event_record_id = insert_event_if_unique(
            conn: conn,
            project_id: project_id,
            issue_id: issue_id,
            normalized_event: normalized_event,
            level_int: level_int,
            occurred_at: occurred_at,
            received_at: received_at,
            now: now
          )

          if event_record_id.nil?
            next PersistResult.new(
              event_id: normalized_event.event_id,
              event_record_id: nil,
              issue_id: issue_id,
              duplicate: true
            )
          end

          apply_issue_occurrence!(
            conn: conn,
            issue_id: issue_id,
            level_int: level_int,
            exception_type: normalized_event.exception_type,
            message: normalized_event.issue_message,
            occurred_at: occurred_at,
            now: now
          )

          PersistResult.new(
            event_id: normalized_event.event_id,
            event_record_id: event_record_id,
            issue_id: issue_id,
            duplicate: false
          )
        end
      end

      private
        def upsert_issue_shell(conn:, project_id:, fingerprint:, level_int:, exception_type:, message:, occurred_at:, now:)
          sql = Issue.sanitize_sql_array([
            <<~SQL.squish,
              INSERT INTO sentrace_issues (
                project_id,
                fingerprint,
                status,
                level,
                exception_type,
                message,
                first_seen_at,
                last_seen_at,
                event_count,
                created_at,
                updated_at
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
              ON CONFLICT (project_id, fingerprint)
              DO UPDATE SET updated_at = sentrace_issues.updated_at
              RETURNING id
            SQL
            project_id,
            fingerprint,
            Issue::STATUSES.fetch(:unresolved),
            level_int,
            exception_type,
            message,
            occurred_at,
            occurred_at,
            now,
            now
          ])

          conn.select_value(sql).to_i
        end

        def insert_event_if_unique(conn:, project_id:, issue_id:, normalized_event:, level_int:, occurred_at:, received_at:, now:)
          sql = Event.sanitize_sql_array([
            <<~SQL.squish,
              INSERT INTO sentrace_events (
                project_id,
                issue_id,
                event_id,
                occurred_at,
                received_at,
                environment,
                release,
                platform,
                level,
                logger,
                culprit,
                event_data,
                created_at
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?)
              ON CONFLICT (project_id, event_id) DO NOTHING
              RETURNING id
            SQL
            project_id,
            issue_id,
            normalized_event.event_id,
            occurred_at,
            received_at,
            normalized_event.environment,
            normalized_event.release,
            normalized_event.platform,
            level_int,
            normalized_event.logger,
            normalized_event.culprit,
            JSON.generate(normalized_event.event_data),
            now
          ])

          raw_id = conn.select_value(sql)
          raw_id ? raw_id.to_i : nil
        end

        def apply_issue_occurrence!(conn:, issue_id:, level_int:, exception_type:, message:, occurred_at:, now:)
          sql = Issue.sanitize_sql_array([
            <<~SQL.squish,
              UPDATE sentrace_issues
              SET event_count = event_count + 1,
                  first_seen_at = LEAST(first_seen_at, ?),
                  last_seen_at = GREATEST(last_seen_at, ?),
                  level = ?,
                  exception_type = COALESCE(?, exception_type),
                  message = COALESCE(?, message),
                  status = CASE WHEN status = ? THEN ? ELSE status END,
                  updated_at = ?
              WHERE id = ?
            SQL
            occurred_at,
            occurred_at,
            level_int,
            exception_type,
            message,
            Issue::STATUSES.fetch(:resolved),
            Issue::STATUSES.fetch(:unresolved),
            now,
            issue_id
          ])

          conn.execute(sql)
        end
    end
  end
end
