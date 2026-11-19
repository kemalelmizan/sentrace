require "openssl"
require "securerandom"

module Sentrace
  class McpToken < ApplicationRecord
    TOKEN_PREFIX_HEADER = "snt_mcp_".freeze
    PREFIX_LENGTH = 12
    MAX_RAW_TOKEN_BYTES = 512
    DUMMY_DIGEST = ("0" * 64).freeze
    ENSURED_TOKEN_FORMAT = /\Asnt_mcp_[A-Za-z0-9_-]{24,256}\z/

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
        return nil unless raw_token.is_a?(String) || raw_token.is_a?(Symbol)

        provided = raw_token.to_s
        return nil if provided.bytesize > MAX_RAW_TOKEN_BYTES

        candidate_digest = digest_token(provided)
        unless provided.start_with?(TOKEN_PREFIX_HEADER)
          ActiveSupport::SecurityUtils.secure_compare(candidate_digest, DUMMY_DIGEST)
          return nil
        end

        records = active.to_a
        if records.empty?
          ActiveSupport::SecurityUtils.secure_compare(candidate_digest, DUMMY_DIGEST)
          return nil
        end

        matched = nil
        records.each do |record|
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

      def ensure!(name: "default", token: nil)
        normalized_name = name.to_s.strip
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        if !token.nil?
          raw_token = token.to_s.strip
          unless raw_token.start_with?(TOKEN_PREFIX_HEADER) && raw_token.match?(ENSURED_TOKEN_FORMAT)
            raise ArgumentError,
              "MCP token must start with '#{TOKEN_PREFIX_HEADER}' and include at least 24 URL-safe secret characters"
          end

          digest = digest_token(raw_token)
          existing = find_by(token_digest: digest)
          if existing
            if !existing.active || existing.revoked_at.present?
              raise ArgumentError, "Provided MCP token has been revoked and cannot be reused"
            end
            return [ existing, nil ]
          end

          record = create_token_idempotently!(
            name: normalized_name,
            token_prefix: raw_token[0, PREFIX_LENGTH],
            token_digest: digest
          )
          [ record, nil ]
        else
          existing_active = active.where(name: normalized_name).order(created_at: :desc, id: :desc).first
          return [ existing_active, nil ] if existing_active

          issue!(name: normalized_name)
        end
      end

      private
        def create_token_idempotently!(name:, token_prefix:, token_digest:)
          transaction(requires_new: true) do
            create!(
              name: name,
              token_prefix: token_prefix,
              token_digest: token_digest,
              active: true,
              created_at: Time.current
            )
          end
        rescue ActiveRecord::RecordNotUnique
          existing = find_by!(token_digest: token_digest)
          if !existing.active || existing.revoked_at.present?
            raise ArgumentError, "Provided MCP token has been revoked and cannot be reused"
          end
          existing
        end

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
