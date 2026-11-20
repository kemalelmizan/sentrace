require "openssl"
require "securerandom"

module Sentrace
  class McpToken < ApplicationRecord
    TOKEN_PREFIX_HEADER = "snt_mcp_".freeze
    PREFIX_LENGTH = 12
    MAX_RAW_TOKEN_BYTES = 512
    DUMMY_DIGEST = ("0" * 64).freeze
    ENSURED_TOKEN_FORMAT = /\Asnt_mcp_[A-Za-z0-9_-]{24,256}\z/
    ALLOWED_SCOPES = %w[read write admin].freeze
    DEFAULT_SCOPES = "read".freeze
    READ_ONLY_SCOPES = "read".freeze
    LAST_USED_TOUCH_INTERVAL = 60

    scope :active, -> { where(active: true, revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

    before_validation :sanitize_name

    validates :name, presence: true, length: { maximum: 120 }
    validates :token_prefix, presence: true, length: { maximum: 16 }
    validates :token_digest, presence: true, length: { is: 64 }, uniqueness: true
    validate :validate_scopes

    class << self
      def digest_token(raw_token)
        OpenSSL::Digest::SHA256.hexdigest(raw_token.to_s)
      end

      def issue!(name: "default", expires_at: nil, expires_in: nil, scopes: nil, read_only: false)
        normalized_name = RequestSecurity.sanitize_single_line(name, max_chars: 120).to_s
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        resolved_expires_at = resolve_expires_at(expires_at: expires_at, expires_in: expires_in)
        resolved_scopes = resolve_scopes(scopes: scopes, read_only: read_only)

        raw_token = "#{TOKEN_PREFIX_HEADER}#{SecureRandom.hex(24)}"
        record = create!(
          name: normalized_name,
          token_prefix: raw_token[0, PREFIX_LENGTH],
          token_digest: digest_token(raw_token),
          active: true,
          expires_at: resolved_expires_at,
          scopes: resolved_scopes,
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

        record = active.find_by(token_digest: candidate_digest)
        unless record
          ActiveSupport::SecurityUtils.secure_compare(candidate_digest, DUMMY_DIGEST)
          return nil
        end

        unless record.token_digest.bytesize == candidate_digest.bytesize &&
               ActiveSupport::SecurityUtils.secure_compare(record.token_digest, candidate_digest)
          return nil
        end

        return nil if record.expired?

        touch_last_used_at(record)
        record
      end

      def rotate!(name: "default", expires_at: nil, expires_in: nil, scopes: nil, read_only: false)
        normalized_name = RequestSecurity.sanitize_single_line(name, max_chars: 120).to_s
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        transaction do
          now = Time.current
          where(name: normalized_name, active: true, revoked_at: nil).find_each do |existing|
            existing.revoke!(at: now)
          end
          issue!(
            name: normalized_name,
            expires_at: expires_at,
            expires_in: expires_in,
            scopes: scopes,
            read_only: read_only
          )
        end
      end

      def ensure!(name: "default", token: nil, expires_at: nil, expires_in: nil, scopes: nil, read_only: false)
        normalized_name = RequestSecurity.sanitize_single_line(name, max_chars: 120).to_s
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        scopes_supplied = !scopes.nil? || read_only
        expiry_supplied = !expires_at.nil? || !expires_in.nil?
        resolved_expires_at = resolve_expires_at(expires_at: expires_at, expires_in: expires_in)
        resolved_scopes = resolve_scopes(scopes: scopes, read_only: read_only)

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
            if existing.expired?
              raise ArgumentError, "Provided MCP token has expired and cannot be reused"
            end
            reconcile_ensured_attributes!(
              existing,
              scopes: resolved_scopes,
              scopes_supplied: scopes_supplied,
              expires_at: resolved_expires_at,
              expiry_supplied: expiry_supplied
            )
            return [ existing, nil ]
          end

          record = create_token_idempotently!(
            name: normalized_name,
            token_prefix: raw_token[0, PREFIX_LENGTH],
            token_digest: digest,
            expires_at: resolved_expires_at,
            scopes: resolved_scopes
          )
          [ record, nil ]
        else
          existing_active = active.where(name: normalized_name).order(created_at: :desc, id: :desc).first
          if existing_active
            reconcile_ensured_attributes!(
              existing_active,
              scopes: resolved_scopes,
              scopes_supplied: scopes_supplied,
              expires_at: resolved_expires_at,
              expiry_supplied: expiry_supplied
            )
            return [ existing_active, nil ]
          end

          issue!(
            name: normalized_name,
            expires_at: resolved_expires_at,
            scopes: resolved_scopes
          )
        end
      end

      private
        def reconcile_ensured_attributes!(record, scopes:, scopes_supplied:, expires_at:, expiry_supplied:)
          updates = {}
          updates[:scopes] = scopes if scopes_supplied && record.scopes != scopes
          updates[:expires_at] = expires_at if expiry_supplied && record.expires_at != expires_at
          record.update!(updates) if updates.any?
        end

        def resolve_expires_at(expires_at:, expires_in:)
          if !expires_at.nil? && !expires_in.nil?
            raise ArgumentError, "Specify either expires_at or expires_in, not both"
          end

          if !expires_in.nil?
            unless expires_in.is_a?(Numeric) && expires_in.positive?
              raise ArgumentError, "expires_in must be a positive duration"
            end

            return Time.current + expires_in
          end

          expires_at
        end

        def resolve_scopes(scopes:, read_only:)
          return READ_ONLY_SCOPES if read_only
          return DEFAULT_SCOPES if scopes.nil?

          parsed =
            case scopes
            when Array
              scopes.map { |s| s.to_s.strip.downcase }
            else
              scopes.to_s.split(",").map { |s| s.strip.downcase }
            end.reject(&:empty?).uniq

          if parsed.empty? || (parsed - ALLOWED_SCOPES).any?
            raise ArgumentError, "scopes must be a non-empty subset of #{ALLOWED_SCOPES.join(', ')}"
          end

          ALLOWED_SCOPES.select { |s| parsed.include?(s) }.join(",")
        end

        def create_token_idempotently!(name:, token_prefix:, token_digest:, expires_at:, scopes:)
          transaction(requires_new: true) do
            create!(
              name: name,
              token_prefix: token_prefix,
              token_digest: token_digest,
              active: true,
              expires_at: expires_at,
              scopes: scopes,
              created_at: Time.current
            )
          end
        rescue ActiveRecord::RecordNotUnique
          existing = find_by!(token_digest: token_digest)
          if !existing.active || existing.revoked_at.present?
            raise ArgumentError, "Provided MCP token has been revoked and cannot be reused"
          end
          if existing.expired?
            raise ArgumentError, "Provided MCP token has expired and cannot be reused"
          end
          existing
        end

        def touch_last_used_at(record)
          now = Time.current
          return if record.last_used_at && record.last_used_at > (now - LAST_USED_TOUCH_INTERVAL)

          record.update_columns(last_used_at: now)
        rescue ActiveRecord::ActiveRecordError
          nil
        end
    end

    def revoke!(at: Time.current)
      update!(active: false, revoked_at: at)
    end

    def expired?(at: Time.current)
      expires_at.present? && expires_at <= at
    end

    def active_now?(at: Time.current)
      active && revoked_at.nil? && !expired?(at: at)
    end

    def scopes_list
      scopes.to_s.split(",").map { |s| s.strip.downcase }.reject(&:empty?).uniq
    end

    def allows_scope?(scope_name)
      scopes_list.include?(scope_name.to_s.downcase)
    end

    def read_only?
      !allows_scope?("write") && !allows_scope?("admin")
    end

    def admin?
      allows_scope?("admin")
    end

    private
      def sanitize_name
        self.name = RequestSecurity.sanitize_single_line(name, max_chars: 120) unless name.nil?
      end

      def validate_scopes
        parsed = scopes_list
        if parsed.empty? || (parsed - ALLOWED_SCOPES).any?
          errors.add(:scopes, "must be a non-empty subset of #{ALLOWED_SCOPES.join(', ')}")
        end
      end
  end
end
