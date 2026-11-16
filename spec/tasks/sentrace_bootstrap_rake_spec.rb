require "rails_helper"
require "rake"

RSpec.describe "sentrace:bootstrap Rake task and Sentrace::Bootstrapper" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  before do
    Rake::Task["sentrace:bootstrap"].reenable
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

  def with_env(overrides)
    saved = overrides.keys.index_with { |k| ENV[k] }
    overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  it "idempotently provisions project DSN key and MCP token digest from CI/CD env vars without echoing raw MCP secrets" do
    env_vars = {
      "SENTRACE_PROJECT_SLUG" => "erp-web",
      "SENTRACE_PROJECT_NAME" => "ERP Monolith",
      "SENTRACE_PROJECT_PUBLIC_KEY" => "erp_pub_1234567890abcdef",
      "SENTRACE_BASE_URL" => "https://errors.example.com/sentrace",
      "SENTRACE_MCP_TOKEN_NAME" => "prod-mcp",
      "SENTRACE_MCP_TOKEN" => "snt_mcp_0123456789abcdef0123456789abcdef"
    }

    with_env(env_vars) do
      first_output = capture_stdout { Rake::Task["sentrace:bootstrap"].invoke }
      Rake::Task["sentrace:bootstrap"].reenable
      second_output = capture_stdout { Rake::Task["sentrace:bootstrap"].invoke }

      project = Sentrace::Project.find_by!(slug: "erp-web")
      expect(project.name).to eq("ERP Monolith")
      expect(project.project_keys.count).to eq(1)
      expect(project.active_key.public_key).to eq("erp_pub_1234567890abcdef")

      token = Sentrace::McpToken.find_by!(name: "prod-mcp")
      expect(Sentrace::McpToken.where(name: "prod-mcp").count).to eq(1)
      expect(Sentrace::McpToken.authenticate("snt_mcp_0123456789abcdef0123456789abcdef")).to eq(token)

      [ first_output, second_output ].each do |out|
        expect(out).to include("SENTRY_DSN=https://erp_pub_1234567890abcdef@errors.example.com/sentrace/#{project.id}")
        expect(out).to include("prefix=snt_mcp_0123")
        expect(out).not_to include("snt_mcp_0123456789abcdef0123456789abcdef")
      end
    end
  end

  it "prints a newly generated MCP token once when SENTRACE_MCP_TOKEN_NAME is set without SENTRACE_MCP_TOKEN" do
    io_first = StringIO.new
    Sentrace::Bootstrapper.new(
      io: io_first,
      env: { "SENTRACE_PROJECT_SLUG" => "dev-app", "SENTRACE_MCP_TOKEN_NAME" => "local-dev" }
    ).run

    generated_raw = io_first.string[/SENTRACE_MCP_TOKEN=(snt_mcp_[0-9a-f]{48})/, 1]
    expect(generated_raw).to be_present
    expect(Sentrace::McpToken.authenticate(generated_raw)).to be_present

    io_second = StringIO.new
    Sentrace::Bootstrapper.new(
      io: io_second,
      env: { "SENTRACE_PROJECT_SLUG" => "dev-app", "SENTRACE_MCP_TOKEN_NAME" => "local-dev" }
    ).run

    expect(io_second.string).not_to include("SENTRACE_MCP_TOKEN=")
  end

  it "exits non-zero via Rake when given an invalid SENTRACE_MCP_TOKEN" do
    with_env(
      "SENTRACE_PROJECT_SLUG" => nil,
      "SENTRACE_MCP_TOKEN_NAME" => "bad",
      "SENTRACE_MCP_TOKEN" => "invalid-short"
    ) do
      expect {
        expect {
          Rake::Task["sentrace:bootstrap"].invoke
        }.to output(/MCP token must start with 'snt_mcp_'/).to_stderr
      }.to raise_error(SystemExit) { |err| expect(err.status).not_to eq(0) }
    end
  end
end
