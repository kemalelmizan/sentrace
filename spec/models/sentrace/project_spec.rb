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
end
