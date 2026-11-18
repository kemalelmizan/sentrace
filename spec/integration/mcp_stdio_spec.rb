require "rails_helper"
require "open3"
require "rake"
require "stringio"
require "tmpdir"

RSpec.describe "Sentrace stdio MCP transport, sentrace:mcp Rake task, and bin/sentrace-mcp" do
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
    expect(lines.size).to eq(3)

    parsed_responses = lines.map { |line| JSON.parse(line) }
    expect(parsed_responses.map { |r| r["id"] }).to eq([ 1, 2, 3 ])

    projects_payload = parsed_responses[1].dig("result", "structuredContent", "projects")
    expect(projects_payload).to include(hash_including("slug" => "stdio-demo", "environment" => "local"))

    issues_payload = parsed_responses[2].dig("result", "structuredContent", "issues")
    expect(issues_payload.size).to eq(1)
    expect(issues_payload.first["message"]).to eq("Stdio test error")
  end

  it "isolates mid-session puts and STDOUT.puts onto err_output without corrupting MCP JSON-RPC frames" do
    noisy_tool = Class.new(MCP::Tool) do
      tool_name "noisy_probe"
      description "Emits stray stdout output while answering"
      input_schema(properties: {})

      class << self
        def call(server_context: nil)
          puts "stray kernel puts during tool call"
          STDOUT.puts "stray STDOUT.puts during tool call"
          MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
        end
      end
    end

    mcp_server = MCP::Server.new(
      name: "sentrace-noisy-spec",
      version: Sentrace::VERSION,
      tools: [ noisy_tool ]
    )

    frames = [
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-11-25",
          capabilities: {},
          clientInfo: { name: "stdio-isolation-spec", version: "0.1.2" }
        }
      },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "noisy_probe", arguments: {} }
      }
    ]
    payload = frames.map { |f| JSON.generate(f) }.join("\n") + "\n"

    in_r, in_w = IO.pipe
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe

    pid = fork do
      in_w.close
      out_r.close
      err_r.close
      STDIN.reopen(in_r)
      STDOUT.reopen(out_w)
      STDERR.reopen(err_w)
      in_r.close
      out_w.close
      err_w.close

      Sentrace::Mcp::StdioRunner.run(server: mcp_server)
      STDOUT.puts "AFTER_RUN_RESTORED"
      STDOUT.flush
      exit!(0)
    end

    in_r.close
    out_w.close
    err_w.close

    in_w.write(payload)
    in_w.close

    raw_stdout = out_r.read
    raw_stderr = err_r.read
    out_r.close
    err_r.close
    _, status = Process.waitpid2(pid)

    expect(status.exitstatus).to eq(0)
    expect(raw_stderr).to include("stray kernel puts during tool call")
    expect(raw_stderr).to include("stray STDOUT.puts during tool call")

    stdout_lines = raw_stdout.lines.map(&:strip).reject(&:empty?)
    expect(stdout_lines.last).to eq("AFTER_RUN_RESTORED")

    rpc_lines = stdout_lines[0...-1]
    expect(rpc_lines.size).to eq(2)
    parsed = rpc_lines.map { |line| JSON.parse(line) }
    expect(parsed.map { |r| r["id"] }).to eq([ 1, 2 ])
  end

  it "boots bin/sentrace-mcp cleanly from /tmp while isolating pre-boot stdout noise onto stderr" do
    Dir.mktmpdir("sentrace-mcp-binstub-app") do |app_dir|
      FileUtils.mkdir_p(File.join(app_dir, "bin"))
      FileUtils.mkdir_p(File.join(app_dir, "config"))

      template_path = File.expand_path("../../lib/generators/sentrace/install/templates/sentrace-mcp.tt", __dir__)
      binstub_path = File.join(app_dir, "bin/sentrace-mcp")
      File.write(binstub_path, File.read(template_path))
      File.chmod(0o755, binstub_path)

      dummy_boot = File.expand_path("../dummy/config/boot.rb", __dir__)
      dummy_env = File.expand_path("../dummy/config/environment.rb", __dir__)

      File.write(
        File.join(app_dir, "config/boot.rb"),
        <<~RUBY
          puts "PRE_BOOT_DOTENV_NOISE"
          STDOUT.puts "PRE_BOOT_NATIVE_STDOUT_NOISE"
          require #{dummy_boot.inspect}
        RUBY
      )

      File.write(
        File.join(app_dir, "config/environment.rb"),
        <<~RUBY
          puts "INITIALIZER_DEPRECATION_NOISE"
          require #{dummy_env.inspect}
        RUBY
      )

      frames = [
        {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2025-11-25",
            capabilities: {},
            clientInfo: { name: "global-ide-host", version: "1.0.0" }
          }
        },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/list",
          params: {}
        }
      ]
      stdin_payload = frames.map { |f| JSON.generate(f) }.join("\n") + "\n"

      stdout_str, stderr_str, status = Open3.capture3(
        { "RAILS_ENV" => "test" },
        binstub_path,
        stdin_data: stdin_payload,
        chdir: Dir.tmpdir
      )

      expect(status.exitstatus).to eq(0), "stderr was:\n#{stderr_str}"
      expect(stderr_str).to include("PRE_BOOT_DOTENV_NOISE")
      expect(stderr_str).to include("PRE_BOOT_NATIVE_STDOUT_NOISE")
      expect(stderr_str).to include("INITIALIZER_DEPRECATION_NOISE")

      lines = stdout_str.lines.map(&:strip).reject(&:empty?)
      expect(lines.size).to eq(2)
      parsed = lines.map { |line| JSON.parse(line) }
      expect(parsed.map { |r| r["id"] }).to eq([ 1, 2 ])

      tool_names = parsed[1].dig("result", "tools").map { |t| t["name"] }
      expect(tool_names).to include("list_environments", "list_projects", "list_issues")
    end
  end

  it "registers the sentrace:mcp Rake task" do
    expect(Rake::Task.task_defined?("sentrace:mcp")).to be(true)
  end
end
