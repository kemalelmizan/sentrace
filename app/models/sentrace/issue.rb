module Sentrace
  class Issue < ApplicationRecord
    STATUSES = {
      unresolved: 0,
      resolved: 1,
      ignored: 2
    }.freeze

    LEVELS = {
      debug: 10,
      info: 20,
      warning: 30,
      error: 40,
      fatal: 50
    }.freeze

    belongs_to :project
    has_many :events, dependent: :destroy

    sentrace_enum :status, STATUSES, default: :unresolved
    sentrace_enum :level, LEVELS, prefix: :level

    validates :fingerprint,
      presence: true,
      length: { maximum: 64 },
      uniqueness: { scope: :project_id }
    validates :exception_type, length: { maximum: 255 }, allow_nil: true
    validates :message, length: { maximum: 1024 }, allow_nil: true
    validates :first_seen_at, :last_seen_at, presence: true
    validates :event_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
