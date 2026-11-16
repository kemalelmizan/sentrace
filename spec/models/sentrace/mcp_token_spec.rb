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
end
