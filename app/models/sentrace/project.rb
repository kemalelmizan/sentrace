module Sentrace
  class Project < ApplicationRecord
    SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

    has_many :project_keys, dependent: :destroy
    has_many :issues, dependent: :destroy
    has_many :events, dependent: :destroy

    validates :name, presence: true, length: { maximum: 120 }
    validates :slug,
      presence: true,
      length: { maximum: 120 },
      uniqueness: true,
      format: { with: SLUG_FORMAT, message: "must be lowercase alphanumeric words separated by hyphens" }

    class << self
      def provision!(slug:, name: nil)
        normalized_slug = slug.to_s.strip.downcase
        derived_name = (name && !name.to_s.strip.empty?) ? name.to_s.strip : normalized_slug.tr("-", " ").titleize

        transaction do
          project = create!(slug: normalized_slug, name: derived_name)
          key = project.project_keys.create!
          [ project, key ]
        end
      end
    end

    def active_key
      project_keys.active.order(created_at: :desc, id: :desc).first
    end

    def rotate_key!
      with_lock do
        now = Time.current
        project_keys.active.find_each do |existing_key|
          existing_key.revoke!(at: now)
        end
        project_keys.create!
      end
    end

    def dsn(base_url:)
      key = active_key
      raise Error, "Project #{slug.inspect} has no active DSN key" unless key

      Dsn.build(base_url: base_url, public_key: key.public_key, project_id: id).to_s
    end
  end
end
