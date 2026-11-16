require "base64"
require "json"
require "time"

module Sentrace
  module Mcp
    class LocalBackend
      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100
      RECENT_EVENTS_PREVIEW_LIMIT = 5

      TREND_BUCKET_SQL = {
        "minute" => "DATE_TRUNC('minute', occurred_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'",
        "hour" => "DATE_TRUNC('hour', occurred_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'",
        "day" => "DATE_TRUNC('day', occurred_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'"
      }.freeze

      attr_reader :environment_name

      def initialize(environment_name: "local")
        @environment_name = environment_name.to_s
      end

      def connection_status
        ActiveRecord::Base.connection.execute("SELECT 1")
        "connected"
      rescue StandardError
        "unreachable"
      end

      def list_projects
        projects = Project.order(:id).map { |project| serialize_project(project) }
        {
          "environment" => @environment_name,
          "projects" => projects
        }
      end

      def list_issues(project_id: nil, status: nil, level: nil, release: nil, since: nil, until: nil, limit: nil, cursor: nil)
        until_param = binding.local_variable_get(:until)
        effective_limit = coerce_limit(limit)
        resolved_project_id = resolve_optional_project_id(project_id)
        normalized_status = validate_optional_status(status)
        normalized_level = validate_optional_level(level)
        since_time = parse_optional_time(since, "since")
        until_time = parse_optional_time(until_param, "until")
        validate_time_window!(since_time, until_time)
        decoded_cursor = decode_cursor(cursor)

        scope = Issue.all
        scope = scope.where(project_id: resolved_project_id) if resolved_project_id
        scope = scope.where(status: Issue::STATUSES.fetch(normalized_status)) if normalized_status
        scope = scope.where(level: Issue::LEVELS.fetch(normalized_level)) if normalized_level
        scope = scope.where("sentrace_issues.last_seen_at >= ?", since_time) if since_time
        scope = scope.where("sentrace_issues.last_seen_at <= ?", until_time) if until_time

        if release && !release.to_s.strip.empty?
          scope = scope.where(
            "EXISTS (SELECT 1 FROM sentrace_events e WHERE e.issue_id = sentrace_issues.id AND e.release = ?)",
            release.to_s.strip
          )
        end

        if decoded_cursor
          scope = scope.where(
            "(sentrace_issues.last_seen_at < ?) OR (sentrace_issues.last_seen_at = ? AND sentrace_issues.id < ?)",
            decoded_cursor[:ts],
            decoded_cursor[:ts],
            decoded_cursor[:id]
          )
        end

        rows = scope.order(last_seen_at: :desc, id: :desc).limit(effective_limit + 1).to_a
        has_more = rows.size > effective_limit
        page_rows = rows.first(effective_limit)

        next_cursor =
          if has_more && page_rows.last
            encode_cursor(ts: page_rows.last.last_seen_at, id: page_rows.last.id)
          end

        {
          "environment" => @environment_name,
          "issues" => page_rows.map { |issue| serialize_issue_summary(issue) },
          "next_cursor" => next_cursor
        }
      end

      def get_issue(issue_id:, project_id: nil)
        issue = find_scoped_issue!(issue_id: issue_id, project_id: project_id)
        release_dist = issue.events.where.not(release: nil).group(:release).count
        env_dist = issue.events.where.not(environment: nil).group(:environment).count
        recent_events = issue.events
          .order(occurred_at: :desc, id: :desc)
          .limit(RECENT_EVENTS_PREVIEW_LIMIT)
          .map { |ev| serialize_event_summary(ev) }

        {
          "environment" => @environment_name,
          "issue" => serialize_issue_summary(issue).merge(
            "release_distribution" => release_dist,
            "environment_distribution" => env_dist,
            "recent_events" => recent_events
          )
        }
      end

      def update_issue_status(issue_id:, status:, project_id: nil)
        normalized_status = validate_required_status(status)
        issue = find_scoped_issue!(issue_id: issue_id, project_id: project_id)
        issue.update!(status: normalized_status)

        {
          "environment" => @environment_name,
          "issue" => serialize_issue_summary(issue)
        }
      end

      def list_events(project_id: nil, issue_id: nil, since: nil, until: nil, limit: nil, cursor: nil)
        until_param = binding.local_variable_get(:until)
        effective_limit = coerce_limit(limit)
        resolved_project_id = resolve_optional_project_id(project_id)
        resolved_issue_id = coerce_optional_positive_int(issue_id, "issue_id")
        since_time = parse_optional_time(since, "since")
        until_time = parse_optional_time(until_param, "until")
        validate_time_window!(since_time, until_time)
        decoded_cursor = decode_cursor(cursor)

        scope = Event.all
        scope = scope.where(project_id: resolved_project_id) if resolved_project_id
        scope = scope.where(issue_id: resolved_issue_id) if resolved_issue_id
        scope = scope.where("sentrace_events.occurred_at >= ?", since_time) if since_time
        scope = scope.where("sentrace_events.occurred_at <= ?", until_time) if until_time

        if decoded_cursor
          scope = scope.where(
            "(sentrace_events.occurred_at < ?) OR (sentrace_events.occurred_at = ? AND sentrace_events.id < ?)",
            decoded_cursor[:ts],
            decoded_cursor[:ts],
            decoded_cursor[:id]
          )
        end

        rows = scope.order(occurred_at: :desc, id: :desc).limit(effective_limit + 1).to_a
        has_more = rows.size > effective_limit
        page_rows = rows.first(effective_limit)

        next_cursor =
          if has_more && page_rows.last
            encode_cursor(ts: page_rows.last.occurred_at, id: page_rows.last.id)
          end

        {
          "environment" => @environment_name,
          "events" => page_rows.map { |ev| serialize_event_summary(ev) },
          "next_cursor" => next_cursor
        }
      end

      def get_event(event_id:, project_id: nil)
        event = find_scoped_event!(event_id: event_id, project_id: project_id)
        {
          "environment" => @environment_name,
          "event" => serialize_event_detail(event)
        }
      end

      def get_error_trends(project_id: nil, since: nil, until: nil, interval: "hour")
        until_param = binding.local_variable_get(:until)
        normalized_interval = (interval || "hour").to_s.strip.downcase
        bucket_expr = TREND_BUCKET_SQL[normalized_interval]
        unless bucket_expr
          raise McpInvalidParamsError, "Unsupported interval #{interval.inspect} (expected minute, hour, or day)"
        end

        resolved_project_id = resolve_optional_project_id(project_id)
        until_time = parse_optional_time(until_param, "until") || Time.current.utc
        since_time = parse_optional_time(since, "since") || (until_time - 24.hours)
        validate_time_window!(since_time, until_time)

        conditions = [ "occurred_at >= ?", "occurred_at <= ?" ]
        binds = [ since_time, until_time ]
        if resolved_project_id
          conditions << "project_id = ?"
          binds << resolved_project_id
        end

        sql = Event.sanitize_sql_array([
          "SELECT #{bucket_expr} AS bucket_start, COUNT(*) AS event_count " \
          "FROM sentrace_events WHERE #{conditions.join(' AND ')} " \
          "GROUP BY 1 ORDER BY 1 ASC",
          *binds
        ])

        raw_rows = Event.connection.select_all(sql).to_a
        buckets = raw_rows.map do |row|
          raw_bucket = row["bucket_start"]
          bucket_time = raw_bucket.is_a?(Time) ? raw_bucket.utc : Time.parse(raw_bucket.to_s).utc
          {
            "bucket_start" => bucket_time.iso8601,
            "count" => row["event_count"].to_i
          }
        end

        {
          "environment" => @environment_name,
          "interval" => normalized_interval,
          "since" => since_time.utc.iso8601,
          "until" => until_time.utc.iso8601,
          "total_events" => buckets.sum { |b| b["count"] },
          "buckets" => buckets
        }
      end

      private
        def serialize_project(project)
          {
            "id" => project.id,
            "slug" => project.slug,
            "name" => project.name,
            "environment" => @environment_name,
            "created_at" => project.created_at.utc.iso8601
          }
        end

        def serialize_issue_summary(issue)
          {
            "id" => issue.id,
            "project_id" => issue.project_id,
            "environment" => @environment_name,
            "fingerprint" => issue.fingerprint,
            "status" => issue.status,
            "level" => issue.level,
            "exception_type" => issue.exception_type,
            "message" => issue.message,
            "first_seen_at" => issue.first_seen_at.utc.iso8601,
            "last_seen_at" => issue.last_seen_at.utc.iso8601,
            "event_count" => issue.event_count
          }
        end

        def serialize_event_summary(event)
          {
            "id" => event.id,
            "event_id" => event.event_id.to_s.strip,
            "project_id" => event.project_id,
            "issue_id" => event.issue_id,
            "environment" => @environment_name,
            "event_environment" => event.environment,
            "release" => event.release,
            "platform" => event.platform,
            "level" => event.level,
            "logger" => event.logger,
            "culprit" => event.culprit,
            "exception_type" => event.event_data.dig("exception", "type"),
            "message" => event.event_data.dig("exception", "value") || event.event_data["message"],
            "occurred_at" => event.occurred_at.utc.iso8601,
            "received_at" => event.received_at.utc.iso8601
          }
        end

        def serialize_event_detail(event)
          data = event.event_data || {}
          serialize_event_summary(event).merge(
            "exception" => data["exception"],
            "raw_message" => data["message"],
            "request" => data["request"],
            "breadcrumbs" => data["breadcrumbs"] || [],
            "tags" => data["tags"] || {},
            "contexts" => data["contexts"] || {},
            "user" => data["user"]
          )
        end

        def find_scoped_issue!(issue_id:, project_id:)
          id = coerce_required_positive_int(issue_id, "issue_id")
          resolved_project_id = resolve_optional_project_id(project_id)

          scope = Issue.where(id: id)
          scope = scope.where(project_id: resolved_project_id) if resolved_project_id
          issue = scope.first
          raise McpNotFoundError, "Issue #{id} not found" unless issue

          issue
        end

        def find_scoped_event!(event_id:, project_id:)
          raw = event_id.to_s.strip
          if raw.empty?
            raise McpInvalidParamsError, "event_id is required"
          end

          resolved_project_id = resolve_optional_project_id(project_id)
          scope = Event.all
          scope = scope.where(project_id: resolved_project_id) if resolved_project_id

          hex_candidate = raw.delete("-").downcase
          event =
            if hex_candidate.match?(Event::EVENT_ID_FORMAT)
              scope.find_by(event_id: hex_candidate)
            elsif raw.match?(/\A\d+\z/)
              scope.find_by(id: Integer(raw, 10))
            else
              raise McpInvalidParamsError, "event_id must be a 32-character hex ID or numeric record ID"
            end

          raise McpNotFoundError, "Event #{raw} not found" unless event

          event
        end

        def resolve_optional_project_id(raw_project_id)
          return nil if raw_project_id.nil? || raw_project_id.to_s.strip.empty?

          str = raw_project_id.to_s.strip
          if str.match?(/\A\d+\z/)
            id = Integer(str, 10)
            raise McpInvalidParamsError, "project_id must be positive" if id <= 0

            id
          else
            project = Project.find_by(slug: str.downcase)
            raise McpNotFoundError, "Project #{str.inspect} not found" unless project

            project.id
          end
        end

        def coerce_required_positive_int(val, name)
          int = coerce_optional_positive_int(val, name)
          raise McpInvalidParamsError, "#{name} is required" if int.nil?

          int
        end

        def coerce_optional_positive_int(val, name)
          return nil if val.nil? || val.to_s.strip.empty?

          int = Integer(val.to_s.strip, 10)
          raise McpInvalidParamsError, "#{name} must be a positive integer" if int <= 0

          int
        rescue ArgumentError, TypeError
          raise McpInvalidParamsError, "#{name} must be a positive integer"
        end

        def coerce_limit(raw_limit)
          return DEFAULT_LIMIT if raw_limit.nil? || raw_limit.to_s.strip.empty?

          int = Integer(raw_limit.to_s.strip, 10)
          if int < 1 || int > MAX_LIMIT
            raise McpInvalidParamsError, "limit must be between 1 and #{MAX_LIMIT}"
          end

          int
        rescue ArgumentError, TypeError
          raise McpInvalidParamsError, "limit must be an integer between 1 and #{MAX_LIMIT}"
        end

        def validate_optional_status(raw_status)
          return nil if raw_status.nil? || raw_status.to_s.strip.empty?

          sym = raw_status.to_s.strip.downcase.to_sym
          unless Issue::STATUSES.key?(sym)
            raise McpInvalidParamsError, "Unsupported status #{raw_status.inspect} (expected unresolved, resolved, or ignored)"
          end

          sym
        end

        def validate_required_status(raw_status)
          sym = validate_optional_status(raw_status)
          raise McpInvalidParamsError, "status is required" unless sym

          sym
        end

        def validate_optional_level(raw_level)
          return nil if raw_level.nil? || raw_level.to_s.strip.empty?

          sym = raw_level.to_s.strip.downcase.to_sym
          unless Issue::LEVELS.key?(sym)
            raise McpInvalidParamsError, "Unsupported level #{raw_level.inspect} (expected debug, info, warning, error, or fatal)"
          end

          sym
        end

        def parse_optional_time(raw_time, name)
          return nil if raw_time.nil? || raw_time.to_s.strip.empty?
          return raw_time.utc if raw_time.is_a?(Time)

          Time.iso8601(raw_time.to_s.strip).utc
        rescue ArgumentError
          raise McpInvalidParamsError, "Invalid ISO-8601 timestamp for #{name}: #{raw_time.inspect}"
        end

        def validate_time_window!(since_time, until_time)
          return unless since_time && until_time

          if since_time > until_time
            raise McpInvalidParamsError, "`since` timestamp cannot be after `until` timestamp"
          end
        end

        def encode_cursor(ts:, id:)
          payload = JSON.generate("ts" => ts.utc.iso8601(6), "id" => id.to_i)
          Base64.urlsafe_encode64(payload, padding: false)
        end

        def decode_cursor(raw_cursor)
          return nil if raw_cursor.nil? || raw_cursor.to_s.strip.empty?

          decoded = JSON.parse(Base64.urlsafe_decode64(raw_cursor.to_s.strip))
          unless decoded.is_a?(Hash) && decoded["ts"].is_a?(String) && decoded["id"].is_a?(Integer)
            raise McpInvalidParamsError, "Invalid pagination cursor"
          end

          { ts: Time.iso8601(decoded["ts"]).utc, id: decoded["id"] }
        rescue ArgumentError, JSON::ParserError
          raise McpInvalidParamsError, "Malformed pagination cursor"
        end
    end
  end
end
