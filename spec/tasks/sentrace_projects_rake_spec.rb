require "rails_helper"
require "rake"

RSpec.describe "sentrace:projects Rake tasks" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  before do
    Rake::Task["sentrace:projects"].reenable
    Rake::Task["sentrace:projects:create"].reenable
    Rake::Task["sentrace:projects:rotate_key"].reenable
  end

  def capture_stdout
    buffer = StringIO.new
    original = $stdout
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = original
  end

  it "creates a project and outputs its ID, slug, public key, and DSN via sentrace:projects:create" do
    output = capture_stdout do
      Rake::Task["sentrace:projects:create"].invoke("my-app")
    end

    project = Sentrace::Project.find_by!(slug: "my-app")
    expect(output).to include("Slug:       my-app")
    expect(output).to include("Public Key: #{project.active_key.public_key}")
    expect(output).to include("@localhost:3000/sentrace/#{project.id}")
  end

  it "lists registered projects and active public keys without exposing secret digests" do
    p1 = create(:sentrace_project, slug: "alpha-web", name: "Alpha Web")
    k1 = create(:sentrace_project_key, project: p1, secret: "hidden-secret-value")
    p2 = create(:sentrace_project, slug: "beta-api", name: "Beta API")
    k2 = create(:sentrace_project_key, project: p2)

    output = capture_stdout do
      Rake::Task["sentrace:projects"].invoke
    end

    expect(output).to include("alpha-web")
    expect(output).to include(k1.public_key)
    expect(output).to include("beta-api")
    expect(output).to include(k2.public_key)
    expect(output).not_to include(k1.secret_digest)
    expect(output).not_to include("hidden-secret-value")
  end

  it "rotates an existing project's key via sentrace:projects:rotate_key" do
    project, old_key = Sentrace::Project.provision!(slug: "billing-service")

    output = capture_stdout do
      Rake::Task["sentrace:projects:rotate_key"].invoke("billing-service")
    end

    old_key.reload
    expect(old_key.active).to be(false)
    expect(project.active_key.public_key).not_to eq(old_key.public_key)
    expect(output).to include(project.active_key.public_key)
  end

  it "exits non-zero with a clear message when rotating an unknown project slug" do
    _, existing_key = Sentrace::Project.provision!(slug: "known-app")

    expect {
      expect {
        Rake::Task["sentrace:projects:rotate_key"].invoke("missing-app")
      }.to output(/Sentrace project 'missing-app' not found/).to_stderr
    }.to raise_error(SystemExit) { |err| expect(err.status).not_to eq(0) }

    expect(existing_key.reload.active).to be(true)
  end
end
