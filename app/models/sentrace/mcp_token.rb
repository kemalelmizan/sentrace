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
    MAX_VERIFIED_CACHE = 256
    VERIFIED_TTL_SECONDS = 300

    @verified_cache_mutex = Mutex.new
    @verified_digests = {}

    belongs_to :project, optional: true

    scope :active, -> { where(active: true, revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

    before_validation :sanitize_name
    after_save :sync_verified_cache
    after_destroy :evict_from_verified_cache

    validates :name, presence: true, length: { maximum: 120 }
    validates :token_prefix, presence: true, length: { maximum: 16 }
    validates :token_digest, presence: true, length: { is: 64 }, uniqueness: true
    validate :validate_scopes

    class << self
      def digest_token(raw_token)
        OpenSSL::Digest::SHA256.hexdigest(raw_token.to_s)
      end

      def clear_verified_cache!
        @verified_cache_mutex.synchronize { @verified_digests.clear }
      end

      def recently_verified_raw_token?(raw_token)
        return false unless raw_token.is_a?(String) || raw_token.is_a?(Symbol)

        provided = raw_token.to_s
        return false if provided.empty? || provided.bytesize > MAX_RAW_TOKEN_BYTES
        return false unless provided.start_with?(TOKEN_PREFIX_HEADER)

        digest = digest_token(provided)
        now = Time.current.to_i
        @verified_cache_mutex.synchronize do
          exp = @verified_digests[digest]
          if exp && exp > now
            true
          else
            @verified_digests.delete(digest) if exp
            false
          end
        end
      end

      def remember_verified_digest(digest, expires_at: nil)
        return if digest.blank?

        now = Time.current.to_i
        ttl_deadline = now + VERIFIED_TTL_SECONDS
        effective_deadline = expires_at ? [ ttl_deadline, expires_at.to_i ].min : ttl_deadline
        return if effective_deadline <= now

        @verified_cache_mutex.synchronize do
          if @verified_digests.size >= MAX_VERIFIED_CACHE && !@verified_digests.key?(digest)
            @verified_digests.delete_if { |_k, v| v <= now }
            if @verified_digests.size >= MAX_VERIFIED_CACHE
              oldest_key, _v = @verified_digests.min_by { |_k, v| v }
              @verified_digests.delete(oldest_key) if oldest_key
            end
          end
          @verified_digests[digest] = effective_deadline
        end
      end

      def forget_verified_digest(digest)
        return if digest.blank?

        @verified_cache_mutex.synchronize { @verified_digests.delete(digest) }
      end

      MAX_PROJECT_ID = (1 << 63) - 1

      def resolve_project_reference(project_ref)
        return nil if project_ref.nil? || project_ref.to_s.strip.empty?
        return project_ref.id if project_ref.is_a?(Project)

        str = project_ref.to_s.strip
        if str.match?(/\A\d+\z/)
          if !str.match?(/\A[1-9]\d{0,18}\z/) || Integer(str, 10) > MAX_PROJECT_ID
            raise ArgumentError, "Project ID #{str.inspect} is out of range"
          end

          project = Project.find_by(id: Integer(str, 10))
          raise ArgumentError, "Project ##{str} not found" unless project

          project.id
        else
          project = Project.find_by(slug: str.downcase)
          raise ArgumentError, "Project #{str.inspect} not found" unless project

          project.id
        end
      end

      def issue!(name: "default", expires_at: nil, expires_in: nil, scopes: nil, read_only: false, project_id: nil)
        normalized_name = RequestSecurity.sanitize_single_line(name, max_chars: 120).to_s
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        resolved_expires_at = resolve_expires_at(expires_at: expires_at, expires_in: expires_in)
        resolved_scopes = resolve_scopes(scopes: scopes, read_only: read_only)
        resolved_project_id = resolve_project_reference(project_id)

        raw_token = "#{TOKEN_PREFIX_HEADER}#{SecureRandom.hex(24)}"
        record = create!(
          name: normalized_name,
          token_prefix: raw_token[0, PREFIX_LENGTH],
          token_digest: digest_token(raw_token),
          active: true,
          expires_at: resolved_expires_at,
          scopes: resolved_scopes,
          project_id: resolved_project_id,
          created_at: Time.current
        )
        remember_verified_digest(record.token_digest, expires_at: record.expires_at)
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
          forget_verified_digest(candidate_digest)
          ActiveSupport::SecurityUtils.secure_compare(candidate_digest, DUMMY_DIGEST)
          return nil
        end

        unless record.token_digest.bytesize == candidate_digest.bytesize &&
               ActiveSupport::SecurityUtils.secure_compare(record.token_digest, candidate_digest)
          forget_verified_digest(candidate_digest)
          return nil
        end

        if record.expired?
          forget_verified_digest(candidate_digest)
          return nil
        end

        remember_verified_digest(record.token_digest, expires_at: record.expires_at)
        touch_last_used_at(record)
        record
      end

      def rotate!(name: "default", expires_at: nil, expires_in: nil, scopes: nil, read_only: false, project_id: nil)
        normalized_name = RequestSecurity.sanitize_single_line(name, max_chars: 120).to_s
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        transaction do
          now = Time.current
          existing_active = where(name: normalized_name, active: true, revoked_at: nil).to_a
          inherited_project_ids = existing_active.map(&:project_id).compact.uniq
          effective_project_id =
            if !project_id.nil? && !project_id.to_s.strip.empty?
              project_id
            elsif inherited_project_ids.one? && existing_active.all? { |t| t.project_id == inherited_project_ids.first }
              inherited_project_ids.first
            end

          existing_active.each do |existing|
            existing.revoke!(at: now)
          end
          issue!(
            name: normalized_name,
            expires_at: expires_at,
            expires_in: expires_in,
            scopes: scopes,
            read_only: read_only,
            project_id: effective_project_id
          )
        end
      end

      def ensure!(name: "default", token: nil, expires_at: nil, expires_in: nil, scopes: nil, read_only: false, project_id: nil)
        normalized_name = RequestSecurity.sanitize_single_line(name, max_chars: 120).to_s
        raise ArgumentError, "Token name is required" if normalized_name.empty?

        scopes_supplied = !scopes.nil? || read_only
        expiry_supplied = !expires_at.nil? || !expires_in.nil?
        project_supplied = !project_id.nil? && !project_id.to_s.strip.empty?
        resolved_expires_at = resolve_expires_at(expires_at: expires_at, expires_in: expires_in)
        resolved_scopes = resolve_scopes(scopes: scopes, read_only: read_only)
        resolved_project_id = resolve_project_reference(project_id)

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
              expiry_supplied: expiry_supplied,
              project_id: resolved_project_id,
              project_supplied: project_supplied
            )
            remember_verified_digest(existing.token_digest, expires_at: existing.expires_at)
            return [ existing, nil ]
          end

          record = create_token_idempotently!(
            name: normalized_name,
            token_prefix: raw_token[0, PREFIX_LENGTH],
            token_digest: digest,
            expires_at: resolved_expires_at,
            scopes: resolved_scopes,
            project_id: resolved_project_id
          )
          remember_verified_digest(record.token_digest, expires_at: record.expires_at)
          [ record, nil ]
        else
          existing_active = active.where(name: normalized_name).order(created_at: :desc, id: :desc).first
          if existing_active
            reconcile_ensured_attributes!(
              existing_active,
              scopes: resolved_scopes,
              scopes_supplied: scopes_supplied,
              expires_at: resolved_expires_at,
              expiry_supplied: expiry_supplied,
              project_id: resolved_project_id,
              project_supplied: project_supplied
            )
            remember_verified_digest(existing_active.token_digest, expires_at: existing_active.expires_at)
            return [ existing_active, nil ]
          end

          issue!(
            name: normalized_name,
            expires_at: resolved_expires_at,
            scopes: resolved_scopes,
            project_id: resolved_project_id
          )
        end
      end

      private
        def reconcile_ensured_attributes!(record, scopes:, scopes_supplied:, expires_at:, expiry_supplied:, project_id: nil, project_supplied: false)
          updates = {}
          updates[:scopes] = scopes if scopes_supplied && record.scopes != scopes
          updates[:expires_at] = expires_at if expiry_supplied && record.expires_at != expires_at
          updates[:project_id] = project_id if project_supplied && record.project_id != project_id
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

        def create_token_idempotently!(name:, token_prefix:, token_digest:, expires_at:, scopes:, project_id: nil)
          transaction(requires_new: true) do
            create!(
              name: name,
              token_prefix: token_prefix,
              token_digest: token_digest,
              active: true,
              expires_at: expires_at,
              scopes: scopes,
              project_id: project_id,
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

      def sync_verified_cache
        if !active || revoked_at.present? || expired?
          self.class.forget_verified_digest(token_digest)
        end
      end

      def evict_from_verified_cache
        self.class.forget_verified_digest(token_digest)
      end

      def validate_scopes
        parsed = scopes_list
        if parsed.empty? || (parsed - ALLOWED_SCOPES).any?
          errors.add(:scopes, "must be a non-empty subset of #{ALLOWED_SCOPES.join(', ')}")
        end
      end
  end
end
