require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "Sentrace stdio MCP transport and sentrace:mcp Rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("sentrace:mcp")
  end

  let!(:project) { Sentrace::Project.provision!(slug: "stdio-demo", name: "Stdio Demo").first }

  it "processes a multi-frame JSON-RPC session over stdio while keeping stdout strictly JSON-RPC" do
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => "1234567890abcdef1234567890abcdef",
        "timestamp" => "2026-11-16T12:00:00Z",
        "message" => "Stdio test error"
      },
      project: project
    )

    frames = [
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-11-25",
          capabilities: {},
          clientInfo: { name: "stdio-spec", version: "0.1.0" }
        }
      },
      {
        jsonrpc: "2.0",
        method: "notifications/initialized"
      },
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "list_projects", arguments: {} }
      },
      {
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: { name: "list_issues", arguments: { project_id: project.id } }
      }
    ]

    input_io = StringIO.new(frames.map { |f| JSON.generate(f) }.join("\n") + "\n")
    output_io = StringIO.new
    err_io = StringIO.new

    Sentrace::Mcp::StdioRunner.run(
      input: input_io,
      output: output_io,
      err_output: err_io
    )

    lines = output_io.string.lines.map(&:strip).reject(&:empty?)
    # Notification produces no output line; 3 requests produce exactly 3 valid JSON-RPC lines
    expect(lines.size).to eq(3)

    parsed_responses = lines.map { |line| JSON.parse(line) }
    expect(parsed_responses.map { |r| r["id"] }).to eq([ 1, 2, 3 ])

    projects_payload = parsed_responses[1].dig("result", "structuredContent", "projects")
    expect(projects_payload).to include(hash_including("slug" => "stdio-demo", "environment" => "local"))

    issues_payload = parsed_responses[2].dig("result", "structuredContent", "issues")
    expect(issues_payload.size).to eq(1)
    expect(issues_payload.first["message"]).to eq("Stdio test error")
  end

  it "registers the sentrace:mcp Rake task" do
    expect(Rake::Task.task_defined?("sentrace:mcp")).to be(true)
  end
end
