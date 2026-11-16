require "uri"
require "sentrace/breadcrumbs/active_support_logger"
require "sentrace/breadcrumbs/http_logger"

module Sentrace
  module Breadcrumbs
    class << self
      def apply_configuration!(config = Sentrace.configuration)
        enabled_loggers = Array(config.breadcrumbs_logger).map(&:to_sym)

        if enabled_loggers.include?(:active_support_logger)
          ActiveSupportLogger.activate!
        else
          ActiveSupportLogger.deactivate!
        end

        if enabled_loggers.include?(:http_logger)
          HttpLogger.activate!
        else
          HttpLogger.deactivate!
        end
      end

      def reset!
        ActiveSupportLogger.deactivate!
        HttpLogger.deactivate!
      end

      def scrub_url(raw_url, config: Sentrace.configuration)
        Ingestion::Sanitizer.sanitize_url(raw_url, nil, config: config)
      end
    end
  end
end
