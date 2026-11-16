module Sentrace
  class RetentionCleanupJob < ActiveJob::Base
    queue_as :default

    def perform
      Retention::Cleaner.run!
    end
  end
end
