module Sentrace
  module Breadcrumbs
    module ActiveSupportLogger
      IGNORED_SQL_NAMES = %w[SCHEMA TRANSACTION EXPLAIN].freeze
      MAX_RAW_SQL_BYTES = 8192
      SQL_DOLLAR_QUOTED_LITERAL = /\$((?:[A-Za-z_][A-Za-z0-9_]*)?)\$[\s\S]*?\$\1\$/
      SQL_SINGLE_QUOTED_LITERAL = /'(?:''|\\'|[^'])*'/
      SQL_OPERATION_REGEX = /\A\s*([A-Za-z]+)/

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
            sanitized_sql = sanitize_sql_statement(raw_sql)
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

          def sanitize_sql_statement(sql)
            bounded_sql = Ingestion::EventNormalizer.truncate_utf8_bytes(sql, MAX_RAW_SQL_BYTES).to_s
            masked = bounded_sql
              .gsub(SQL_DOLLAR_QUOTED_LITERAL, "'?'")
              .gsub(SQL_SINGLE_QUOTED_LITERAL, "'?'")
            collapsed = masked.gsub(/\s+/, " ").strip
            Ingestion::EventNormalizer.truncate_utf8_bytes(collapsed, 256)
          end

          def scrub_url_or_path(raw_path)
            return nil if raw_path.nil? || raw_path.empty?

            Breadcrumbs.scrub_url(raw_path)
          end
      end
    end
  end
end
