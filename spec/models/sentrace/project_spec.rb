require "rails_helper"

RSpec.describe Sentrace::Project, type: :model do
  describe "validations and uniqueness" do
    it "persists valid projects and enforces unique lowercase slugs" do
      create(:sentrace_project, slug: "checkout-web", name: "Checkout Web")

      duplicate = build(:sentrace_project, slug: "checkout-web")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to include("has already been taken")

      expect {
        described_class.connection.execute(
          "INSERT INTO sentrace_projects (name, slug, created_at, updated_at) VALUES ('Dup', 'checkout-web', NOW(), NOW())"
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "rejects invalid slug formats" do
      project = build(:sentrace_project, slug: "Invalid Slug!")
      expect(project).not_to be_valid
    end
  end

  describe ".provision! and #rotate_key!" do
    it "provisions a project with an active key and formats a DSN" do
      project, key = described_class.provision!(slug: "my-app")

      expect(project).to be_persisted
      expect(project.name).to eq("My App")
      expect(key).to be_persisted
      expect(key.active).to be(true)
      expect(project.active_key).to eq(key)
      expect(project.dsn(base_url: "https://errors.example.com/sentrace")).to eq(
        "https://#{key.public_key}@errors.example.com/sentrace/#{project.id}"
      )
    end

    it "revokes previous keys and issues a new active key on #rotate_key!" do
      project, old_key = described_class.provision!(slug: "rotatable-app")

      new_key = project.rotate_key!
      old_key.reload

      expect(old_key.active).to be(false)
      expect(old_key.revoked_at).to be_present
      expect(new_key.active).to be(true)
      expect(new_key.public_key).not_to eq(old_key.public_key)
      expect(project.active_key).to eq(new_key)

      expect(
        Sentrace::ProjectKey.authenticate_public_key(project_id: project.id, public_key: old_key.public_key)
      ).to be_nil
      expect(
        Sentrace::ProjectKey.authenticate_public_key(project_id: project.id, public_key: new_key.public_key)
      ).to eq(new_key)
    end
  end

  describe ".ensure!" do
    it "idempotently ensures a project and pinned public_key across repeated boots without rotating or duplicating" do
      pinned_key = "pub_prod_0123456789abcdef"

      project1, key1 = described_class.ensure!(slug: "core-monolith", public_key: pinned_key)
      project2, key2 = described_class.ensure!(slug: "core-monolith", public_key: pinned_key)

      expect(project1).to eq(project2)
      expect(key1).to eq(key2)
      expect(key1.public_key).to eq(pinned_key)
      expect(project1.project_keys.count).to eq(1)
      expect(project1.active_key).to eq(key1)

      auto_project, auto_key = described_class.ensure!(slug: "worker-app")
      _, auto_key_repeat = described_class.ensure!(slug: "worker-app")
      expect(auto_key_repeat).to eq(auto_key)
      expect(auto_project.project_keys.count).to eq(1)
    end

    it "rejects malformed, cross-project, or revoked public_key values in .ensure!" do
      _other_project, other_key = described_class.ensure!(slug: "alpha-app", public_key: "alpha_pub_0123456789abcdef")

      expect {
        described_class.ensure!(slug: "beta-app", public_key: "short")
      }.to raise_error(ArgumentError, /public_key must be 16..64/)

      expect {
        described_class.ensure!(slug: "beta-app", public_key: other_key.public_key)
      }.to raise_error(ArgumentError, /already assigned to another project/)

      other_key.revoke!
      expect {
        described_class.ensure!(slug: "alpha-app", public_key: other_key.public_key)
      }.to raise_error(ArgumentError, /revoked key/)
    end
  end
end
