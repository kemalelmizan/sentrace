module Sentrace
  class Project < ApplicationRecord
    SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    PUBLIC_KEY_FORMAT = /\A[A-Za-z0-9_-]{16,64}\z/

    has_many :project_keys, dependent: :destroy
    has_many :issues, dependent: :destroy
    has_many :events, dependent: :destroy

    after_save :invalidate_runtime_caches
    after_destroy :invalidate_runtime_caches

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

      def ensure!(slug:, name: nil, public_key: nil)
        normalized_slug = slug.to_s.strip.downcase
        raise ArgumentError, "Project slug is required" if normalized_slug.empty?

        provided_pub = public_key.nil? ? nil : public_key.to_s.strip
        if !provided_pub.nil? && !provided_pub.match?(PUBLIC_KEY_FORMAT)
          raise ArgumentError, "public_key must be 16..64 URL-safe alphanumeric characters"
        end

        derived_name = (name && !name.to_s.strip.empty?) ? name.to_s.strip : normalized_slug.tr("-", " ").titleize
        project = find_or_create_project!(slug: normalized_slug, name: derived_name)

        project.with_lock do
          if provided_pub
            existing_key = ProjectKey.find_by(public_key: provided_pub)
            if existing_key
              if existing_key.project_id != project.id
                raise ArgumentError, "public_key is already assigned to another project"
              end
              if !existing_key.active || existing_key.revoked_at.present?
                raise ArgumentError, "public_key belongs to a revoked key and cannot be reused"
              end
              [ project, existing_key ]
            else
              [ project, project.project_keys.create!(public_key: provided_pub) ]
            end
          else
            [ project, project.active_key || project.project_keys.create! ]
          end
        end
      end

      private
        def find_or_create_project!(slug:, name:)
          existing = find_by(slug: slug)
          return existing if existing

          transaction(requires_new: true) do
            create!(slug: slug, name: name)
          end
        rescue ActiveRecord::RecordNotUnique
          find_by!(slug: slug)
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

    private
      def invalidate_runtime_caches
        CaptureDispatcher.clear_cache! if defined?(CaptureDispatcher)
        FrontendDsnResolver.clear_cache! if defined?(FrontendDsnResolver)
      end
  end
end
