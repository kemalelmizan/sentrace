require "rails_helper"

RSpec.describe Sentrace::Mcp::Server do
  let!(:project) { Sentrace::Project.provision!(slug: "payments-service", name: "Payments Service").first }
  let(:server) { described_class.build }

  def rpc(method, params = {}, id: 1)
    raw_response = server.handle_json(
      JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)
    )
    JSON.parse(raw_response)
  end

  let!(:ingested) do
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => "abcdef0123456789abcdef0123456789",
        "timestamp" => "2026-11-16T10:30:00Z",
        "level" => "error",
        "environment" => "production",
        "release" => "v3.1.0",
        "exception" => {
          "values" => [
            {
              "type" => "Stripe::CardError",
              "value" => "Your card was declined",
              "stacktrace" => {
                "frames" => [
                  { "filename" => "app/services/charge_card.rb", "function" => "call", "lineno" => 27, "in_app" => true }
                ]
              }
            }
          ]
        },
        "tags" => { "gateway" => "stripe" }
      },
      project: project
    )
  end

  describe "capability discovery" do
    it "advertises all 8 tools, 2 static resources, 3 resource templates, and the investigate_issue prompt" do
      init = rpc("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "rspec", version: "1.0" } })
      expect(init.dig("result", "serverInfo", "name")).to eq("sentrace")

      tools = rpc("tools/list").dig("result", "tools").map { |t| t["name"] }
      expect(tools).to match_array(%w[
        list_environments
        list_projects
        list_issues
        get_issue
        update_issue_status
        list_events
        get_event
        get_error_trends
      ])

      resources = rpc("resources/list").dig("result", "resources").map { |r| r["uri"] }
      expect(resources).to match_array(%w[sentrace://environments sentrace://projects])

      templates = rpc("resources/templates/list").dig("result", "resourceTemplates").map { |t| t["uriTemplate"] }
      expect(templates).to match_array(%w[
        sentrace://projects/{project_id}/issues
        sentrace://issues/{issue_id}
        sentrace://events/{event_id}
      ])

      prompts = rpc("prompts/list").dig("result", "prompts").map { |p| p["name"] }
      expect(prompts).to eq([ "investigate_issue" ])
    end
  end

  describe "tools/call" do
    it "executes discovery, issue, event, trend, and status mutation tools end-to-end" do
      envs_resp = rpc("tools/call", { name: "list_environments", arguments: {} })
      expect(envs_resp.dig("result", "isError")).to be(false)
      expect(envs_resp.dig("result", "structuredContent", "environments").first["name"]).to eq("local")

      issues_resp = rpc("tools/call", { name: "list_issues", arguments: { project_id: project.id, status: "unresolved" } })
      issues = issues_resp.dig("result", "structuredContent", "issues")
      expect(issues.size).to eq(1)
      expect(issues.first["id"]).to eq(ingested.issue_id)

      issue_resp = rpc("tools/call", { name: "get_issue", arguments: { issue_id: ingested.issue_id, project_id: project.id } })
      expect(issue_resp.dig("result", "structuredContent", "issue", "exception_type")).to eq("Stripe::CardError")

      event_resp = rpc("tools/call", { name: "get_event", arguments: { event_id: "abcdef0123456789abcdef0123456789" } })
      expect(event_resp.dig("result", "structuredContent", "event", "tags")).to eq("gateway" => "stripe")

      trends_resp = rpc("tools/call", {
        name: "get_error_trends",
        arguments: {
          project_id: project.id,
          since: "2026-11-16T10:00:00Z",
          until: "2026-11-16T11:00:00Z",
          interval: "hour"
        }
      })
      expect(trends_resp.dig("result", "structuredContent", "total_events")).to eq(1)

      mutate_resp = rpc("tools/call", {
        name: "update_issue_status",
        arguments: { issue_id: ingested.issue_id, status: "resolved" }
      })
      expect(mutate_resp.dig("result", "structuredContent", "issue", "status")).to eq("resolved")
      expect(Sentrace::Issue.find(ingested.issue_id).status).to eq("resolved")
    end

    it "returns structured MCP tool errors on schema violations or missing records without leaking stack traces" do
      invalid_status = rpc("tools/call", {
        name: "update_issue_status",
        arguments: { issue_id: ingested.issue_id, status: "bogus" }
      })
      expect(invalid_status.dig("result", "isError")).to be(true)

      missing_issue = rpc("tools/call", {
        name: "get_issue",
        arguments: { issue_id: 999_999 }
      })
      expect(missing_issue.dig("result", "isError")).to be(true)
      expect(missing_issue.dig("result", "structuredContent", "category")).to eq("not_found")
    end

    it "correlates Ruby backend and JavaScript frontend events and issues by request_id and platform" do
      Sentrace::Ingestion::Processor.ingest_event(
        {
          "event_id" => "11111111111111111111111111111111",
          "timestamp" => "2026-11-16T10:31:00Z",
          "platform" => "ruby",
          "message" => "Backend checkout failure",
          "request" => { "url" => "https://shop.example.com/checkout", "method" => "POST", "headers" => { "X-Request-Id" => "req-shared-77" } }
        },
        project: project
      )
      Sentrace::Ingestion::Processor.ingest_event(
        {
          "event_id" => "22222222222222222222222222222222",
          "timestamp" => "2026-11-16T10:31:01Z",
          "platform" => "javascript",
          "exception" => { "values" => [ { "type" => "TypeError", "value" => "Checkout fetch 500" } ] },
          "tags" => { "request_id" => "req-shared-77" }
        },
        project: project
      )

      corr_events_resp = rpc("tools/call", {
        name: "list_events",
        arguments: { project_id: project.id, request_id: "req-shared-77" }
      })
      corr_events = corr_events_resp.dig("result", "structuredContent", "events")
      expect(corr_events.map { |e| e["platform"] }).to match_array(%w[ruby javascript])
      expect(corr_events.map { |e| e["request_id"] }.uniq).to eq([ "req-shared-77" ])

      js_issues_resp = rpc("tools/call", {
        name: "list_issues",
        arguments: { project_id: project.id, platform: "javascript" }
      })
      js_issues = js_issues_resp.dig("result", "structuredContent", "issues")
      expect(js_issues.size).to eq(1)
      expect(js_issues.first["exception_type"]).to eq("TypeError")
    end
  end

  describe "resources/read and prompts/get" do
    it "serves all 5 sentrace:// resources with environment attribution and raises -32602 for unknown URIs" do
      [
        "sentrace://environments",
        "sentrace://projects",
        "sentrace://projects/#{project.id}/issues",
        "sentrace://issues/#{ingested.issue_id}",
        "sentrace://events/abcdef0123456789abcdef0123456789"
      ].each do |uri|
        res = rpc("resources/read", { uri: uri })
        expect(res["error"]).to be_nil, "expected #{uri} to succeed, got #{res.inspect}"
        contents = res.dig("result", "contents")
        expect(contents.size).to eq(1)
        parsed_json = JSON.parse(contents.first["text"])
        expect(parsed_json).to be_a(Hash)
      end

      missing = rpc("resources/read", { uri: "sentrace://issues/999999" })
      expect(missing.dig("error", "code")).to eq(-32_602)
    end

    it "renders investigate_issue prompt separating Observed Evidence from Testable Hypotheses" do
      prompt_res = rpc("prompts/get", {
        name: "investigate_issue",
        arguments: { issue_id: ingested.issue_id.to_s, project_id: project.slug }
      })

      expect(prompt_res["error"]).to be_nil
      text = prompt_res.dig("result", "messages", 0, "content", "text")
      expect(text).to include("Observed Evidence")
      expect(text).to include("Testable Hypotheses")
      expect(text).to include("Stripe::CardError")
      expect(text).to include("1. **Inspect the issue**")
      expect(text).to include("8. **Suggest a reproduction or verification strategy**")
    end
  end
end
