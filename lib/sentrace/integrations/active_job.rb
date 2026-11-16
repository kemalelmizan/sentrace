require "active_support/concern"

module Sentrace
  module Integrations
    module ActiveJob
      extend ActiveSupport::Concern

      included do
        around_perform do |job, block|
          Sentrace.with_scope do |scope|
            scope.set_context(
              "active_job",
              {
                "job_class" => job.class.name.to_s,
                "job_id" => job.job_id.to_s,
                "queue_name" => job.queue_name.to_s,
                "executions" => job.executions
              }
            )
            scope.set_tag("queue", job.queue_name.to_s) if job.queue_name && !scope.tags.key?("queue")
            scope.set_transaction_name(job.class.name.to_s) unless scope.transaction_name

            begin
              block.call
            rescue Exception => e # rubocop:disable Lint/RescueException
              unless e.is_a?(SystemExit) || e.is_a?(SignalException)
                mechanism = Sidekiq.active_in_current_thread? ? "sidekiq" : "active_job"
                ExceptionDeduplicator.capture_unhandled_once(e, mechanism_type: mechanism)
              end
              raise
            end
          end
        end
      end
    end
  end
end
