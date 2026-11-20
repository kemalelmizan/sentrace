require "rails_helper"

RSpec.describe "Sentrace Internal Administrative API (/sentrace/internal)", type: :request do
  after { Sentrace.reset_configuration! }

  let!(:token_pair) { Sentrace::McpToken.issue!(name: "admin-spec", scopes: "read,write,admin") }
  let(:raw_token) { token_pair.last }
  let(:auth_headers) { { "Authorization" => "Bearer #{raw_token}" } }
  let(:base_url) { "https://app.example.com" }

  describe "authentication, HTTPS enforcement, and host policy integration" do
    it "rejects non-loopback plain HTTP requests with 403 and unauthenticated/DSN requests over HTTPS with 401" do
      _proj, dsn_key = Sentrace::Project.provision!(slug: "guarded-app")

      get "http://app.example.com/sentrace/internal/projects", headers: auth_headers
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to include("HTTPS is required")

      get "#{base_url}/sentrace/internal/projects"
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Cache-Control"]).to eq("no-store")

      get "#{base_url}/sentrace/internal/projects", headers: { "Authorization" => "Bearer #{dsn_key.public_key}" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "supports host-provided config.internal_authenticator policies (SPEC.md §9.3)" do
      Sentrace.configure do |c|
        c.internal_authenticator = ->(req) { req.headers["X-Host-Admin"] == "allow-ops" }
      end

      get "#{base_url}/sentrace/internal/projects"
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Cache-Control"]).to eq("no-store")

      get "#{base_url}/sentrace/internal/projects", headers: { "X-Host-Admin" => "allow-ops" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "projects, issues, events, and stats endpoints" do
    it "manages projects with admin scope, lists/updates issues, inspects events, and returns storage stats without exposing secret digests" do
      post "#{base_url}/sentrace/internal/projects",
        params: { slug: "orders-service", name: "Orders Service" },
        headers: auth_headers
      expect(response).to have_http_status(:created)
      created_proj = JSON.parse(response.body).fetch("project")
      project_id = created_proj.fetch("id")
      expect(created_proj["slug"]).to eq("orders-service")
      expect(created_proj["dsn"]).to include("/#{project_id}")
      expect(created_proj).not_to have_key("secret_digest")

      patch "#{base_url}/sentrace/internal/projects/#{project_id}",
        params: { name: "Orders Core Service" },
        headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("project", "name")).to eq("Orders Core Service")

      ingest_res = Sentrace::Ingestion::Processor.ingest_event(
        {
          "event_id" => "abcdef0123456789abcdef0123456789",
          "timestamp" => "2026-11-16T05:00:00Z",
          "level" => "error",
          "message" => "Order validation failed"
        },
        project: project_id,
        received_at: Time.utc(2026, 11, 16, 5, 0, 5)
      )

      get "#{base_url}/sentrace/internal/issues", params: { project_id: project_id }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      issues = JSON.parse(response.body).fetch("issues")
      expect(issues.size).to eq(1)
      issue_id = issues.first.fetch("id")

      patch "#{base_url}/sentrace/internal/issues/#{issue_id}",
        params: { status: "ignored" },
        headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("issue", "status")).to eq("ignored")

      get "#{base_url}/sentrace/internal/issues/#{issue_id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("issue", "status")).to eq("ignored")

      get "#{base_url}/sentrace/internal/events", params: { issue_id: issue_id }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).fetch("events").size).to eq(1)

      get "#{base_url}/sentrace/internal/events/#{ingest_res.event_id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("event", "event_id")).to eq("abcdef0123456789abcdef0123456789")

      get "#{base_url}/sentrace/internal/stats", headers: auth_headers
      expect(response).to have_http_status(:ok)
      stats = JSON.parse(response.body)
      expect(stats["total_events"]).to eq(1)
      expect(stats["database_storage_bytes"]).to be > 0

      delete "#{base_url}/sentrace/internal/projects/#{project_id}", headers: auth_headers
      expect(response).to have_http_status(:no_content)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(Sentrace::Project.where(id: project_id)).to be_empty
      expect(Sentrace::Event.where(project_id: project_id)).to be_empty
    end

    it "returns HTTP 422 with Cache-Control: no-store on blank slug, duplicate slug, or invalid filter params" do
      post "#{base_url}/sentrace/internal/projects",
        params: { slug: "   " },
        headers: auth_headers
      expect(response).to have_http_status(422)
      expect(response.headers["Cache-Control"]).to eq("no-store")

      Sentrace::Project.provision!(slug: "dup-proj")
      post "#{base_url}/sentrace/internal/projects",
        params: { slug: "dup-proj" },
        headers: auth_headers
      expect(response).to have_http_status(422)
      expect(response.headers["Cache-Control"]).to eq("no-store")

      get "#{base_url}/sentrace/internal/issues",
        params: { status: "invalid-status" },
        headers: auth_headers
      expect(response).to have_http_status(422)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "enforces internal_allowed_ips, rate limits, write scope on issues, and admin scope on project mutations/credentials" do
      Sentrace.configure { |c| c.internal_allowed_ips = [ "10.0.0.0/8" ] }

      get "#{base_url}/sentrace/internal/projects", headers: auth_headers.merge("REMOTE_ADDR" => "203.0.113.9")
      expect(response).to have_http_status(:forbidden)

      get "#{base_url}/sentrace/internal/projects", headers: auth_headers.merge("REMOTE_ADDR" => "10.1.2.3")
      expect(response).to have_http_status(:ok)

      Sentrace.reset_configuration!
      _ro_record, ro_raw = Sentrace::McpToken.issue!(name: "internal-ro", read_only: true)
      ro_headers = { "Authorization" => "Bearer #{ro_raw}" }
      _rw_record, rw_raw = Sentrace::McpToken.issue!(name: "internal-rw")
      rw_headers = { "Authorization" => "Bearer #{rw_raw}" }

      proj, _ = Sentrace::Project.provision!(slug: "ro-internal-proj")
      ingest_res = Sentrace::Ingestion::Processor.ingest_event(
        {
          "event_id" => "cccc1111dddd2222eeee3333ffff4444",
          "timestamp" => "2026-11-16T05:00:00Z",
          "level" => "error",
          "message" => "Internal RO check"
        },
        project: proj.id,
        received_at: Time.utc(2026, 11, 16, 5, 0, 5)
      )

      # Non-admin tokens can list projects with DSN/public_key redacted, but cannot create, update, or destroy projects
      [ ro_headers, rw_headers ].each do |hdrs|
        get "#{base_url}/sentrace/internal/projects", headers: hdrs
        expect(response).to have_http_status(:ok)
        listed = JSON.parse(response.body).fetch("projects").find { |p| p["id"] == proj.id }
        expect(listed["public_key"]).to be_nil
        expect(listed["dsn"]).to be_nil

        post "#{base_url}/sentrace/internal/projects", params: { slug: "rogue-proj" }, headers: hdrs
        expect(response).to have_http_status(:forbidden)

        patch "#{base_url}/sentrace/internal/projects/#{proj.id}", params: { slug: "hijacked-slug" }, headers: hdrs
        expect(response).to have_http_status(:forbidden)

        delete "#{base_url}/sentrace/internal/projects/#{proj.id}", headers: hdrs
        expect(response).to have_http_status(:forbidden)
      end
      expect(proj.reload.slug).to eq("ro-internal-proj")

      # Read-only cannot update issue status; read,write can
      get "#{base_url}/sentrace/internal/issues", params: { project_id: proj.id }, headers: ro_headers
      expect(response).to have_http_status(:ok)

      patch "#{base_url}/sentrace/internal/issues/#{ingest_res.issue_id}", params: { status: "resolved" }, headers: ro_headers
      expect(response).to have_http_status(:forbidden)

      patch "#{base_url}/sentrace/internal/issues/#{ingest_res.issue_id}", params: { status: "resolved" }, headers: rw_headers
      expect(response).to have_http_status(:ok)

      # Auth failure rate limit also protects /sentrace/internal/*
      Sentrace.configure { |c| c.mcp_auth_failure_limit_per_minute = 2 }
      bad_hdrs = { "Authorization" => "Bearer snt_mcp_invalid0000000000000000000000000", "REMOTE_ADDR" => "198.51.100.88" }
      2.times do
        get "#{base_url}/sentrace/internal/projects", headers: bad_hdrs
        expect(response).to have_http_status(:unauthorized)
      end
      get "#{base_url}/sentrace/internal/projects", headers: bad_hdrs
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"].to_i).to be >= 1
    end
  end
end
