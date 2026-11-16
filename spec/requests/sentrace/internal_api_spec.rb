require "rails_helper"

RSpec.describe "Sentrace Internal Administrative API (/sentrace/internal)", type: :request do
  after { Sentrace.reset_configuration! }

  let!(:token_pair) { Sentrace::McpToken.issue!(name: "admin-spec") }
  let(:raw_token) { token_pair.last }
  let(:auth_headers) { { "Authorization" => "Bearer #{raw_token}" } }

  describe "authentication and host policy integration" do
    it "rejects unauthenticated requests and ingestion DSN keys with 401 Unauthorized" do
      _proj, dsn_key = Sentrace::Project.provision!(slug: "guarded-app")

      get "/sentrace/internal/projects"
      expect(response).to have_http_status(:unauthorized)

      get "/sentrace/internal/projects", headers: { "Authorization" => "Bearer #{dsn_key.public_key}" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "supports host-provided config.internal_authenticator policies (SPEC.md §9.3)" do
      Sentrace.configure do |c|
        c.internal_authenticator = ->(req) { req.headers["X-Host-Admin"] == "allow-ops" }
      end

      get "/sentrace/internal/projects"
      expect(response).to have_http_status(:unauthorized)

      get "/sentrace/internal/projects", headers: { "X-Host-Admin" => "allow-ops" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "projects, issues, events, and stats endpoints" do
    it "manages projects, lists/updates issues, inspects events, and returns storage stats without exposing secret digests" do
      post "/sentrace/internal/projects",
        params: { slug: "orders-service", name: "Orders Service" },
        headers: auth_headers
      expect(response).to have_http_status(:created)
      created_proj = JSON.parse(response.body).fetch("project")
      project_id = created_proj.fetch("id")
      expect(created_proj["slug"]).to eq("orders-service")
      expect(created_proj["dsn"]).to include("/#{project_id}")
      expect(created_proj).not_to have_key("secret_digest")

      patch "/sentrace/internal/projects/#{project_id}",
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
        project: project_id
      )

      get "/sentrace/internal/issues", params: { project_id: project_id }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      issues = JSON.parse(response.body).fetch("issues")
      expect(issues.size).to eq(1)
      issue_id = issues.first.fetch("id")

      patch "/sentrace/internal/issues/#{issue_id}",
        params: { status: "ignored" },
        headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("issue", "status")).to eq("ignored")

      get "/sentrace/internal/issues/#{issue_id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("issue", "status")).to eq("ignored")

      get "/sentrace/internal/events", params: { issue_id: issue_id }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).fetch("events").size).to eq(1)

      get "/sentrace/internal/events/#{ingest_res.event_id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("event", "event_id")).to eq("abcdef0123456789abcdef0123456789")

      get "/sentrace/internal/stats", headers: auth_headers
      expect(response).to have_http_status(:ok)
      stats = JSON.parse(response.body)
      expect(stats["total_events"]).to eq(1)
      expect(stats["database_storage_bytes"]).to be > 0

      delete "/sentrace/internal/projects/#{project_id}", headers: auth_headers
      expect(response).to have_http_status(:no_content)
      expect(Sentrace::Project.where(id: project_id)).to be_empty
    end
  end
end
