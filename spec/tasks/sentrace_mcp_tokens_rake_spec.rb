require "rails_helper"
require "rake"

RSpec.describe "sentrace:mcp:tokens Rake tasks" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  before do
    Rake::Task["sentrace:mcp:tokens"].reenable
    Rake::Task["sentrace:mcp:tokens:create"].reenable
    Rake::Task["sentrace:mcp:tokens:rotate"].reenable
    Rake::Task["sentrace:mcp:tokens:revoke"].reenable
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

  it "creates an MCP token, prints the raw token once, and lists only prefix/status without digest or plaintext" do
    create_output = capture_stdout do
      Rake::Task["sentrace:mcp:tokens:create"].invoke("staging")
    end

    token = Sentrace::McpToken.find_by!(name: "staging")
    expect(token.scopes).to eq("read")
    expect(token.read_only?).to be(true)
    raw_match = create_output.match(/Token:\s+(snt_mcp_[0-9a-f]{48})/)
    expect(raw_match).to be_present
    raw_token = raw_match[1]
    expect(Sentrace::McpToken.authenticate(raw_token)).to eq(token)

    list_output = capture_stdout do
      Rake::Task["sentrace:mcp:tokens"].invoke
    end

    expect(list_output).to include("staging")
    expect(list_output).to include(token.token_prefix)
    expect(list_output).to include("active")
    expect(list_output).not_to include(raw_token)
    expect(list_output).not_to include(token.token_digest)
  end

  it "rotates and revokes MCP tokens cleanly via Rake tasks" do
    old_token, old_raw = Sentrace::McpToken.issue!(name: "default")

    rotate_output = capture_stdout do
      Rake::Task["sentrace:mcp:tokens:rotate"].invoke("default")
    end

    expect(old_token.reload.active).to be(false)
    expect(Sentrace::McpToken.authenticate(old_raw)).to be_nil

    new_raw = rotate_output[/Token:\s+(snt_mcp_[0-9a-f]{48})/, 1]
    new_token = Sentrace::McpToken.authenticate(new_raw)
    expect(new_token).to be_present

    revoke_output = capture_stdout do
      Rake::Task["sentrace:mcp:tokens:revoke"].invoke(new_token.id.to_s)
    end

    expect(revoke_output).to include("Revoked Sentrace MCP token ##{new_token.id}")
    expect(Sentrace::McpToken.authenticate(new_raw)).to be_nil
  end

  it "exits non-zero when revoking an unknown token ID" do
    expect {
      expect {
        Rake::Task["sentrace:mcp:tokens:revoke"].invoke("999999")
      }.to output(/Sentrace MCP token #999999 not found/).to_stderr
    }.to raise_error(SystemExit) { |err| expect(err.status).not_to eq(0) }
  end
end
