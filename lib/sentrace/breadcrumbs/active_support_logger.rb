module Sentrace
  module Breadcrumbs
    module ActiveSupportLogger
      IGNORED_SQL_NAMES = %w[SCHEMA TRANSACTION EXPLAIN].freeze
      MAX_RAW_SQL_BYTES = 8192
      SQL_OPERATION_REGEX = /\A\s*([A-Za-z]+)/
      DOLLAR_TAG_REGEX = /\G\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/

      @mutex = Mutex.new
      @subscribers = []

      class << self
        def activate!
          return unless defined?(ActiveSupport::Notifications)

          @mutex.synchronize do
            return if @subscribers.any?

            @subscribers << ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              record_controller_action(event)
            end

            @subscribers << ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              record_sql_query(event)
            end
          end
        end

        def deactivate!
          return unless defined?(ActiveSupport::Notifications)

          @mutex.synchronize do
            @subscribers.each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }
            @subscribers.clear
          end
        end

        def active?
          @mutex.synchronize { @subscribers.any? }
        end

        private
          def record_controller_action(event)
            return unless should_record?

            payload = event.payload || {}
            controller = payload[:controller].to_s
            return if controller.empty? || controller.start_with?("Sentrace::")

            action = payload[:action].to_s
            status = payload[:status]
            has_error = payload[:exception].present? || (status.is_a?(Integer) && status >= 500)
            safe_path = scrub_url_or_path(payload[:path].to_s)

            data = {
              "controller" => controller,
              "action" => action,
              "method" => payload[:method]&.to_s,
              "path" => safe_path,
              "status_code" => status,
              "duration_ms" => event.duration&.round(2)
            }.compact

            Sentrace.add_breadcrumb(
              type: "http",
              category: "process_action.action_controller",
              level: has_error ? "error" : "info",
              message: "#{controller}##{action}",
              data: data
            )
          rescue StandardError
            nil
          end

          def record_sql_query(event)
            return unless should_record?

            payload = event.payload || {}
            name = payload[:name].to_s
            return if IGNORED_SQL_NAMES.include?(name)

            raw_sql = payload[:sql].to_s
            return if raw_sql.empty? || raw_sql.include?("sentrace_")

            operation = raw_sql[SQL_OPERATION_REGEX, 1]&.upcase
            adapter_name = payload[:connection].respond_to?(:adapter_name) ? payload[:connection].adapter_name.to_s : ""
            sanitized_sql = sanitize_sql_statement(raw_sql, adapter_name: adapter_name)
            label = name.empty? ? (operation || "SQL") : name

            data = {
              "name" => label,
              "operation" => operation,
              "statement" => sanitized_sql,
              "cached" => payload[:cached] == true ? true : nil,
              "duration_ms" => event.duration&.round(2)
            }.compact

            Sentrace.add_breadcrumb(
              type: "query",
              category: "sql.active_record",
              level: "info",
              message: label,
              data: data
            )
          rescue StandardError
            nil
          end

          def should_record?
            Sentrace.configuration.enabled && !Thread.current[CaptureDispatcher::REENTRANCY_KEY]
          end

          def sanitize_sql_statement(sql, adapter_name: "")
            bounded_sql = Ingestion::EventNormalizer.truncate_utf8_bytes(sql, MAX_RAW_SQL_BYTES).to_s
            backslash_escapes = adapter_name.to_s.match?(/mysql|trilogy/i)
            masked = mask_sql_literals_and_comments(bounded_sql, backslash_escapes: backslash_escapes)
            collapsed = masked.gsub(/\s+/, " ").strip
            redacted = Ingestion::Sanitizer.redact_inline_secrets(collapsed)
            Ingestion::EventNormalizer.truncate_utf8_bytes(redacted, 256)
          end

          def mask_sql_literals_and_comments(sql, backslash_escapes: false)
            out = +""
            pos = 0
            len = sql.length

            while pos < len
              ch = sql[pos]

              if ch == "-" && sql[pos + 1] == "-"
                nl = sql.index("\n", pos + 2)
                out << " "
                pos = nl ? (nl + 1) : len
              elsif ch == "/" && sql[pos + 1] == "*"
                close_comment = sql.index("*/", pos + 2)
                out << " "
                pos = close_comment ? (close_comment + 2) : len
              elsif ch == '"'
                out << '"'
                pos += 1
                while pos < len
                  if sql[pos] == '"'
                    if sql[pos + 1] == '"'
                      out << '""'
                      pos += 2
                    else
                      out << '"'
                      pos += 1
                      break
                    end
                  else
                    out << sql[pos]
                    pos += 1
                  end
                end
              elsif (ch == "E" || ch == "e") && sql[pos + 1] == "'" &&
                    (pos.zero? || !sql[pos - 1].match?(/[A-Za-z0-9_]/))
                out << "'?'"
                pos = consume_single_quoted_literal(sql, pos + 2, len, allow_backslash_escape: true)
              elsif ch == "'"
                out << "'?'"
                pos = consume_single_quoted_literal(sql, pos + 1, len, allow_backslash_escape: backslash_escapes)
              elsif ch == "$" && (tag_match = DOLLAR_TAG_REGEX.match(sql, pos))
                tag = tag_match[0]
                close_idx = sql.index(tag, tag_match.end(0))
                out << "'?'"
                pos = close_idx ? (close_idx + tag.length) : len
              else
                out << ch
                pos += 1
              end
            end

            out
          end

          def consume_single_quoted_literal(sql, pos, len, allow_backslash_escape:)
            while pos < len
              cur = sql[pos]
              if allow_backslash_escape && cur == "\\"
                pos += 2
              elsif cur == "'"
                if sql[pos + 1] == "'"
                  pos += 2
                else
                  return pos + 1
                end
              else
                pos += 1
              end
            end
            len
          end

          def scrub_url_or_path(raw_path)
            return nil if raw_path.nil? || raw_path.empty?

            Breadcrumbs.scrub_url(raw_path)
          end
      end
    end
  end
end
