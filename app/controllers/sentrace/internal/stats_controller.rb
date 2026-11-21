module Sentrace
  module Internal
    class StatsController < BaseController
      MAX_STATS_DAYS = 365

      def show
        if @current_mcp_token&.project_id
          return render json: { error: "Forbidden: project-scoped token cannot access global storage stats" }, status: :forbidden
        end

        raw_days = scalar_param(:days)
        days = raw_days.nil? || raw_days.to_s.strip.empty? ? 30 : parse_days!(raw_days)
        render json: StorageStats.collect(days: days)
      end

      private
        def parse_days!(raw_days)
          parsed = Integer(raw_days.to_s.strip, 10)
          unless (1..MAX_STATS_DAYS).cover?(parsed)
            raise McpInvalidParamsError, "days must be between 1 and #{MAX_STATS_DAYS}"
          end

          parsed
        rescue ArgumentError, TypeError
          raise McpInvalidParamsError, "days must be between 1 and #{MAX_STATS_DAYS}"
        end
    end
  end
end
