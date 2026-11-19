require "openssl"
require "securerandom"

module Sentrace
  class ProjectKey < ApplicationRecord
    MAX_PUBLIC_KEY_INPUT_BYTES = 128
    MAX_SECRET_INPUT_BYTES = 512
    DUMMY_DIGEST = ("0" * 64).freeze

    belongs_to :project

    scope :active, -> { where(active: true, revoked_at: nil) }

    before_validation :ensure_public_key, on: :create
    after_save :invalidate_runtime_caches
    after_destroy :invalidate_runtime_caches

    validates :public_key, presence: true, length: { maximum: 64 }, uniqueness: true
    validates :secret_digest, length: { maximum: 255 }, allow_nil: true

    class << self
      def digest_secret(raw_secret)
        OpenSSL::Digest::SHA256.hexdigest(raw_secret.to_s)
      end

      def authenticate_public_key(project_id:, public_key:, secret: nil)
        return nil if project_id.blank? || public_key.blank?
        return nil unless public_key.is_a?(String) || public_key.is_a?(Symbol)
        return nil if !secret.nil? && !secret.is_a?(String) && !secret.is_a?(Symbol)

        provided_pub = public_key.to_s
        return nil if provided_pub.bytesize > MAX_PUBLIC_KEY_INPUT_BYTES
        return nil if !secret.nil? && secret.to_s.bytesize > MAX_SECRET_INPUT_BYTES

        provided_pub_digest = digest_secret(provided_pub)
        candidates = active.where(project_id: project_id).to_a
        if candidates.empty?
          ActiveSupport::SecurityUtils.secure_compare(provided_pub_digest, DUMMY_DIGEST)
          return nil
        end

        matched = nil
        candidates.each do |key|
          candidate_pub_digest = digest_secret(key.public_key)
          if ActiveSupport::SecurityUtils.secure_compare(candidate_pub_digest, provided_pub_digest) &&
             key.public_key.bytesize == provided_pub.bytesize &&
             ActiveSupport::SecurityUtils.secure_compare(key.public_key, provided_pub)
            matched = key
          end
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
      return false unless candidate.is_a?(String) || candidate.is_a?(Symbol)
      return false if candidate.to_s.bytesize > MAX_SECRET_INPUT_BYTES

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

      def invalidate_runtime_caches
        CaptureDispatcher.clear_cache! if defined?(CaptureDispatcher)
        FrontendDsnResolver.clear_cache! if defined?(FrontendDsnResolver)
      end
  end
end
