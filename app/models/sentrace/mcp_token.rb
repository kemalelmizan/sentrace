require "openssl"
require "securerandom"

module Sentrace
  class McpToken < ApplicationRecord
    TOKEN_PREFIX_HEADER = "snt_mcp_".freeze
    PREFIX_LENGTH = 12

    scope :active, -> { where(active: true, revoked_at: nil) }

    validates :name, presence: true, length: { maximum: 120 }
    validates :token_prefix, presence: true, length: { maximum: 16 }
    validates :token_digest, presence: true, length: { is: 64 }, uniqueness: true

    class << self
      def digest_token(raw_token)
        OpenSSL::Digest::SHA256.hexdigest(raw_token.to_s)
      end

      def issue!(name: "default")
        normalized_name = name.to_s.strip
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        raw_token = "#{TOKEN_PREFIX_HEADER}#{SecureRandom.hex(24)}"
        record = create!(
          name: normalized_name,
          token_prefix: raw_token[0, PREFIX_LENGTH],
          token_digest: digest_token(raw_token),
          active: true,
          created_at: Time.current
        )
        [ record, raw_token ]
      end

      def authenticate(raw_token)
        return nil if raw_token.blank?

        provided = raw_token.to_s
        return nil unless provided.start_with?(TOKEN_PREFIX_HEADER)

        candidate_digest = digest_token(provided)
        matched = nil

        active.to_a.each do |record|
          if record.token_digest.bytesize == candidate_digest.bytesize &&
             ActiveSupport::SecurityUtils.secure_compare(record.token_digest, candidate_digest)
            matched = record
          end
        end

        return nil unless matched

        touch_last_used_at(matched)
        matched
      end

      def rotate!(name: "default")
        normalized_name = name.to_s.strip
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        transaction do
          now = Time.current
          active.where(name: normalized_name).find_each do |existing|
            existing.revoke!(at: now)
          end
          issue!(name: normalized_name)
        end
      end

      private
        def touch_last_used_at(record)
          record.update_columns(last_used_at: Time.current)
        rescue ActiveRecord::ActiveRecordError
          nil
        end
    end

    def revoke!(at: Time.current)
      update!(active: false, revoked_at: at)
    end
  end
end
