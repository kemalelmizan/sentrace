require "openssl"
require "securerandom"

module Sentrace
  class ProjectKey < ApplicationRecord
    belongs_to :project

    scope :active, -> { where(active: true, revoked_at: nil) }

    before_validation :ensure_public_key, on: :create

    validates :public_key, presence: true, length: { maximum: 64 }, uniqueness: true
    validates :secret_digest, length: { maximum: 255 }, allow_nil: true

    class << self
      def digest_secret(raw_secret)
        OpenSSL::Digest::SHA256.hexdigest(raw_secret.to_s)
      end

      def authenticate_public_key(project_id:, public_key:, secret: nil)
        return nil if project_id.blank? || public_key.blank?

        provided_pub = public_key.to_s
        candidates = active.where(project_id: project_id).to_a

        matched = candidates.find do |key|
          key.public_key.bytesize == provided_pub.bytesize &&
            ActiveSupport::SecurityUtils.secure_compare(key.public_key, provided_pub)
        end

        return nil unless matched
        return nil if matched.secret_digest.present? && !matched.verify_secret(secret)

        matched
      end
    end

    def secret=(raw_secret)
      @secret = nil
      self.secret_digest = raw_secret.present? ? self.class.digest_secret(raw_secret) : nil
    end

    def verify_secret(candidate)
      return false if secret_digest.blank? || candidate.blank?

      candidate_digest = self.class.digest_secret(candidate)
      secret_digest.bytesize == candidate_digest.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(secret_digest, candidate_digest)
    end

    def revoke!(at: Time.current)
      update!(active: false, revoked_at: at)
    end

    private
      def ensure_public_key
        self.public_key = SecureRandom.hex(16) if public_key.blank?
      end
  end
end
