require "rails_helper"

RSpec.describe Sentrace::McpToken do
  describe ".issue! and .authenticate" do
    it "persists only a SHA-256 digest and non-secret prefix, authenticates valid tokens, and updates last_used_at" do
      record, raw_token = described_class.issue!(name: "staging-federation")

      expect(raw_token).to start_with("snt_mcp_")
      expect(raw_token.bytesize).to eq(56)
      expect(record.name).to eq("staging-federation")
      expect(record.token_prefix).to eq(raw_token[0, 12])
      expect(record.token_digest).to eq(OpenSSL::Digest::SHA256.hexdigest(raw_token))
      expect(record.token_digest).not_to eq(raw_token)
      expect(record.attributes.values).not_to include(raw_token)
      expect(record.last_used_at).to be_nil

      authenticated = described_class.authenticate(raw_token)
      expect(authenticated).to eq(record)
      expect(authenticated.reload.last_used_at).to be_present
    end

    it "rejects blank, malformed, tampered, revoked, and ingestion DSN public_key tokens" do
      _project, dsn_key = Sentrace::Project.provision!(slug: "web-app")
      record, raw_token = described_class.issue!(name: "default")

      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate("")).to be_nil
      expect(described_class.authenticate("#{raw_token}x")).to be_nil
      expect(described_class.authenticate(dsn_key.public_key)).to be_nil
      expect(described_class.authenticate("snt_mcp_#{dsn_key.public_key}")).to be_nil

      record.revoke!
      expect(record.active).to be(false)
      expect(record.revoked_at).to be_present
      expect(described_class.authenticate(raw_token)).to be_nil
    end
  end

  describe ".rotate!" do
    it "revokes active tokens for the target name, issues a replacement, and leaves ingestion DSNs untouched" do
      project, dsn_key = Sentrace::Project.provision!(slug: "core-api")
      old_record, old_raw = described_class.issue!(name: "production")
      other_record, other_raw = described_class.issue!(name: "ci-reader")

      new_record, new_raw = described_class.rotate!(name: "production")

      expect(old_record.reload.active).to be(false)
      expect(old_record.revoked_at).to be_present
      expect(described_class.authenticate(old_raw)).to be_nil

      expect(new_record.active).to be(true)
      expect(new_raw).not_to eq(old_raw)
      expect(described_class.authenticate(new_raw)).to eq(new_record)

      expect(other_record.reload.active).to be(true)
      expect(described_class.authenticate(other_raw)).to eq(other_record)

      expect(dsn_key.reload.active).to be(true)
      expect(
        Sentrace::ProjectKey.authenticate_public_key(project_id: project.id, public_key: dsn_key.public_key)
      ).to eq(dsn_key)
    end
  end

  describe ".ensure!" do
    it "idempotently seeds a provided snt_mcp_ token as SHA-256 digest only without duplicating rows" do
      env_token = "snt_mcp_0123456789abcdef0123456789abcdef"

      record1, issued1 = described_class.ensure!(name: "prod-mcp", token: env_token)
      record2, issued2 = described_class.ensure!(name: "prod-mcp", token: env_token)

      expect(record1).to eq(record2)
      expect(issued1).to be_nil
      expect(issued2).to be_nil
      expect(described_class.where(name: "prod-mcp").count).to eq(1)
      expect(record1.token_prefix).to eq("snt_mcp_0123")
      expect(record1.token_digest).to eq(OpenSSL::Digest::SHA256.hexdigest(env_token))
      expect(record1.attributes.values).not_to include(env_token)
      expect(described_class.authenticate(env_token)).to eq(record1)
    end

    it "issues once when token is nil and rejects weak, unprefixed, or revoked tokens" do
      gen_record, gen_raw = described_class.ensure!(name: "local-cli")
      repeat_record, repeat_raw = described_class.ensure!(name: "local-cli")

      expect(gen_raw).to start_with("snt_mcp_")
      expect(repeat_record).to eq(gen_record)
      expect(repeat_raw).to be_nil

      expect {
        described_class.ensure!(name: "bad", token: "plain_secret_0123456789abcdef0123456789")
      }.to raise_error(ArgumentError, /start with 'snt_mcp_'/)

      expect {
        described_class.ensure!(name: "bad", token: "snt_mcp_too_short")
      }.to raise_error(ArgumentError, /at least 24/)

      revoked_raw = "snt_mcp_fedcba9876543210fedcba9876543210"
      revoked_rec, _ = described_class.ensure!(name: "revoked-env", token: revoked_raw)
      revoked_rec.revoke!

      expect {
        described_class.ensure!(name: "revoked-env", token: revoked_raw)
      }.to raise_error(ArgumentError, /revoked/)
    end
  end

  describe "expiration and scopes" do
    it "enforces expires_at / expires_in in .active and .authenticate" do
      expired_record, expired_raw = described_class.issue!(name: "short-lived", expires_at: 1.minute.ago)
      valid_record, valid_raw = described_class.issue!(name: "valid-ttl", expires_in: 1.hour)

      expect(expired_record.expired?).to be(true)
      expect(expired_record.active_now?).to be(false)
      expect(described_class.active).not_to include(expired_record)
      expect(described_class.authenticate(expired_raw)).to be_nil

      expect(valid_record.expired?).to be(false)
      expect(valid_record.active_now?).to be(true)
      expect(described_class.active).to include(valid_record)
      expect(described_class.authenticate(valid_raw)).to eq(valid_record)
    end

    it "supports read_only and scopes on issue!, rotate!, and ensure!" do
      ro_record, _ro_raw = described_class.issue!(name: "ci-reader", read_only: true)
      expect(ro_record.scopes).to eq("read")
      expect(ro_record.read_only?).to be(true)
      expect(ro_record.allows_scope?("read")).to be(true)
      expect(ro_record.allows_scope?("write")).to be(false)

      rw_record, _rw_raw = described_class.rotate!(name: "ci-reader", scopes: %w[read write])
      expect(rw_record.scopes).to eq("read,write")
      expect(rw_record.read_only?).to be(false)

      expect {
        described_class.issue!(name: "bad-scope", scopes: "admin")
      }.to raise_error(ArgumentError, /scopes must be a non-empty subset/)
    end
  end
end
