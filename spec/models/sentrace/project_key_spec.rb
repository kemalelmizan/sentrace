require "rails_helper"

RSpec.describe Sentrace::ProjectKey, type: :model do
  it "generates a 32-char hex public key and stores secrets only as SHA-256 digests" do
    key = create(:sentrace_project_key, public_key: nil, secret: "raw-secret-material")

    expect(key.public_key).to match(/\A[0-9a-f]{32}\z/)
    expect(key.secret_digest).to eq(OpenSSL::Digest::SHA256.hexdigest("raw-secret-material"))
    expect(key.attributes.values).not_to include("raw-secret-material")
    expect(key.verify_secret("raw-secret-material")).to be(true)
    expect(key.verify_secret("wrong-secret")).to be(false)
  end

  it "authenticates an active public key only against its owning project" do
    project_one = create(:sentrace_project)
    project_two = create(:sentrace_project)
    key_one = create(:sentrace_project_key, project: project_one, public_key: "pub_one_0123456789abcdef")
    create(:sentrace_project_key, project: project_two, public_key: "pub_two_0123456789abcdef")

    expect(
      described_class.authenticate_public_key(project_id: project_one.id, public_key: "pub_one_0123456789abcdef")
    ).to eq(key_one)

    expect(
      described_class.authenticate_public_key(project_id: project_two.id, public_key: "pub_one_0123456789abcdef")
    ).to be_nil
  end

  it "rejects authentication when secret_digest is set and wrong secret is given" do
    key = create(:sentrace_project_key, secret: "expected-secret")

    expect(
      described_class.authenticate_public_key(project_id: key.project_id, public_key: key.public_key)
    ).to be_nil

    expect(
      described_class.authenticate_public_key(
        project_id: key.project_id,
        public_key: key.public_key,
        secret: "expected-secret"
      )
    ).to eq(key)
  end
end
