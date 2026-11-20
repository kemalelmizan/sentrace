require "rails_helper"

RSpec.describe Sentrace::Mcp::LocalBackend do
  subject(:backend) { described_class.new(environment_name: "local") }

  let!(:project) { Sentrace::Project.provision!(slug: "core-api", name: "Core API").first }

  def ingest(event_id: SecureRandom.hex(16), fingerprint:, occurred_at:, release: "v1.0.0", env: "production", level: "error", type: "RuntimeError", value: "Boom")
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => event_id,
        "timestamp" => occurred_at.iso8601,
        "level" => level,
        "environment" => env,
        "release" => release,
        "fingerprint" => [ fingerprint ],
        "exception" => {
          "values" => [
            {
              "type" => type,
              "value" => value,
              "stacktrace" => {
                "frames" => [
                  { "filename" => "app/jobs/sync_job.rb", "function" => "perform", "lineno" => 12, "in_app" => true }
                ]
              }
            }
          ]
        },
        "tags" => { "queue" => "critical" },
        "breadcrumbs" => [ { "category" => "job", "message" => "Started sync" } ]
      },
      project: project,
      received_at: occurred_at
    )
  end

  describe "#list_projects" do
    it "returns projects attributed to the backend environment without exposing keys" do
      result = backend.list_projects
      expect(result["environment"]).to eq("local")
      expect(result["projects"]).to contain_exactly(
        hash_including("id" => project.id, "slug" => "core-api", "name" => "Core API", "environment" => "local")
      )
    end
  end

  describe "#list_issues and #get_issue" do
    it "supports filtering, deterministic keyset cursor pagination, and detailed issue inspection" do
      t0 = Time.utc(2026, 11, 16, 9, 0, 0)
      r1 = ingest(fingerprint: "fp-1", occurred_at: t0, release: "v1.0.0", env: "staging", level: "warning", value: "Issue 1")
      r2 = ingest(fingerprint: "fp-2", occurred_at: t0 + 10.minutes, release: "v1.1.0", env: "production", level: "error", value: "Issue 2")
      ingest(fingerprint: "fp-2", occurred_at: t0 + 15.minutes, release: "v1.2.0", env: "staging", level: "error", value: "Issue 2")
      r3 = ingest(fingerprint: "fp-3", occurred_at: t0 + 20.minutes, release: "v1.2.0", env: "production", level: "fatal", value: "Issue 3")

      page1 = backend.list_issues(project_id: project.id, limit: 2)
      expect(page1["environment"]).to eq("local")
      expect(page1["issues"].map { |i| i["id"] }).to eq([ r3.issue_id, r2.issue_id ])
      expect(page1["next_cursor"]).to be_present

      page2 = backend.list_issues(project_id: "core-api", limit: 2, cursor: page1["next_cursor"])
      expect(page2["issues"].map { |i| i["id"] }).to eq([ r1.issue_id ])
      expect(page2["next_cursor"]).to be_nil

      filtered = backend.list_issues(project_id: project.id, release: "v1.1.0", level: "error")
      expect(filtered["issues"].map { |i| i["id"] }).to eq([ r2.issue_id ])

      detail = backend.get_issue(issue_id: r2.issue_id, project_id: project.id)["issue"]
      expect(detail["event_count"]).to eq(2)
      expect(detail["release_distribution"]).to eq("v1.1.0" => 1, "v1.2.0" => 1)
      expect(detail["environment_distribution"]).to eq("production" => 1, "staging" => 1)
      expect(detail["recent_events"].size).to eq(2)
    end
  end

  describe "#update_issue_status" do
    it "transitions issue status across unresolved, resolved, and ignored and rejects invalid statuses" do
      res = ingest(fingerprint: "fp-mut", occurred_at: Time.utc(2026, 11, 16, 10, 0, 0))

      resolved = backend.update_issue_status(issue_id: res.issue_id, project_id: project.id, status: "resolved")
      expect(resolved.dig("issue", "status")).to eq("resolved")

      ignored = backend.update_issue_status(issue_id: res.issue_id, project_id: project.id, status: "ignored")
      expect(ignored.dig("issue", "status")).to eq("ignored")

      expect {
        backend.update_issue_status(issue_id: res.issue_id, status: "deleted")
      }.to raise_error(Sentrace::McpInvalidParamsError, /Unsupported status/)
    end
  end

  describe "#list_events and #get_event" do
    it "paginates events without N+1 bloat and retrieves full normalized event context by hex ID or record ID" do
      ev_hex = "abcdef0123456789abcdef0123456789"
      res = ingest(event_id: ev_hex, fingerprint: "fp-ev", occurred_at: Time.utc(2026, 11, 16, 10, 0, 0))
      ingest(fingerprint: "fp-ev", occurred_at: Time.utc(2026, 11, 16, 10, 5, 0))

      list = backend.list_events(project_id: project.id, issue_id: res.issue_id, limit: 1)
      expect(list["events"].size).to eq(1)
      expect(list["next_cursor"]).to be_present

      by_hex = backend.get_event(event_id: ev_hex, project_id: project.id)["event"]
      by_pk = backend.get_event(event_id: res.event_record_id)["event"]

      expect(by_hex["event_id"]).to eq(ev_hex)
      expect(by_pk["id"]).to eq(res.event_record_id)
      expect(by_hex.dig("exception", "frames")).not_to be_empty
      expect(by_hex["tags"]).to eq("queue" => "critical")
      expect(by_hex["breadcrumbs"].first["message"]).to eq("Started sync")
    end
  end

  describe "#get_error_trends" do
    it "computes hourly buckets directly from sentrace_events without creating database rows" do
      ingest(fingerprint: "fp-t", occurred_at: Time.utc(2026, 11, 16, 10, 15, 0))
      ingest(fingerprint: "fp-t", occurred_at: Time.utc(2026, 11, 16, 10, 45, 0))
      ingest(fingerprint: "fp-t", occurred_at: Time.utc(2026, 11, 16, 11, 5, 0))

      trends = nil
      expect {
        trends = backend.get_error_trends(
          project_id: project.id,
          since: "2026-11-16T10:00:00Z",
          until: "2026-11-16T12:00:00Z",
          interval: "hour"
        )
      }.not_to change { [ Sentrace::Event.count, Sentrace::Issue.count ] }

      expect(trends["total_events"]).to eq(3)
      expect(trends["buckets"]).to eq([
        { "bucket_start" => "2026-11-16T10:00:00Z", "count" => 2 },
        { "bucket_start" => "2026-11-16T11:00:00Z", "count" => 1 }
      ])

      expect {
        backend.get_error_trends(interval: "1 hour; DROP TABLE sentrace_events")
      }.to raise_error(Sentrace::McpInvalidParamsError, /Unsupported interval/)
    end
  end

  describe "parameter validation" do
    it "rejects oversized limits, malformed cursors, inverted time windows, and missing records" do
      expect { backend.list_issues(limit: 500) }.to raise_error(Sentrace::McpInvalidParamsError, /limit/)
      expect { backend.list_issues(cursor: "not-base64-json!!") }.to raise_error(Sentrace::McpInvalidParamsError, /cursor/)
      expect {
        backend.list_issues(since: "2026-11-16T12:00:00Z", until: "2026-11-16T10:00:00Z")
      }.to raise_error(Sentrace::McpInvalidParamsError, /since/)
      expect { backend.get_issue(issue_id: 999_999) }.to raise_error(Sentrace::McpNotFoundError)
    end
  end
end
