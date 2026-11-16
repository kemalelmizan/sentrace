module Sentrace
  class Event < ApplicationRecord
    EVENT_ID_FORMAT = /\A[0-9a-f]{32}\z/

    class << self
      def dangerous_attribute_method?(method_name)
        return false if method_name == "logger" || method_name == "logger?"

        super
      end
    end

    belongs_to :project
    belongs_to :issue

    sentrace_enum :level, Issue::LEVELS, prefix: :level

    before_validation :normalize_event_id

    validates :event_id,
      presence: true,
      format: { with: EVENT_ID_FORMAT, message: "must be a 32-character lowercase hex string" },
      uniqueness: { scope: :project_id }
    validates :occurred_at, :received_at, presence: true
    validates :environment, length: { maximum: 64 }, allow_nil: true
    validates :release, length: { maximum: 128 }, allow_nil: true
    validates :platform, length: { maximum: 32 }, allow_nil: true
    validates :logger, length: { maximum: 128 }, allow_nil: true
    validates :culprit, length: { maximum: 512 }, allow_nil: true
    validate :event_data_must_be_hash

    private
      def normalize_event_id
        self.event_id = event_id.to_s.strip.delete("-").downcase if event_id.present?
      end

      def event_data_must_be_hash
        errors.add(:event_data, "must be a JSON object") unless event_data.is_a?(Hash)
      end
  end
end
