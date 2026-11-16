require "rails_helper"

RSpec.describe Sentrace::Mcp::Dispatcher do
  self.use_transactional_tests = false

  after do
    Sentrace::Event.delete_all
    Sentrace::Issue.delete_all
    Sentrace::ProjectKey.delete_all
    Sentrace::Project.delete_all
    Sentrace::McpToken.delete_all
  end
  let(:config) do
    Sentrace::Configuration.new.tap do |c|
      c.environments = {
        local: { transport: :local },
        staging: {
          transport: :http,
          url: "https://staging.example.com/sentrace/mcp",
          token: "super-secret-staging-token"
        }
      }
    end
  end

  let(:unreachable_requester) do
    ->(**_args) { raise SocketError, "getaddrinfo: nodename nor servname provided" }
  end
  let(:remote_client) { Sentrace::Mcp::RemoteHttpClient.new(http_requester: unreachable_requester) }

  subject(:dispatcher) { described_class.new(config: config, remote_client: remote_client) }

  describe "#list_environments" do
    it "lists configured environments with connection status and never exposes tokens" do
      result = dispatcher.list_environments
      serialized = JSON.generate(result)

      expect(serialized).not_to include("super-secret-staging-token")
      expect(result["environments"]).to contain_exactly(
        hash_including("name" => "local", "transport" => "local", "status" => "connected"),
        hash_including(
          "name" => "staging",
          "transport" => "http",
          "url" => "https://staging.example.com/sentrace/mcp",
          "status" => "unreachable"
        )
      )
    end
  end

  describe "#dispatch" do
    let!(:project) { Sentrace::Project.provision!(slug: "web-app").first }

    it "routes default/local operations to LocalBackend and rejects unknown environments or 'all' mutations" do
      projects_res = dispatcher.dispatch(:list_projects)
      expect(projects_res["environment"]).to eq("local")
      expect(projects_res["projects"].first["slug"]).to eq("web-app")

      expect {
        dispatcher.dispatch(:list_projects, environment: "nonexistent")
      }.to raise_error(Sentrace::McpInvalidParamsError, /Unknown environment/)

      expect {
        dispatcher.dispatch(:update_issue_status, environment: "all", issue_id: 1, status: "resolved")
      }.to raise_error(Sentrace::McpInvalidParamsError, /Mutations cannot target 'all'/)
    end

    it "isolates unavailable remote environments during 'all' queries without hiding local results" do
      federated = dispatcher.dispatch(:list_projects, environment: "all")
      serialized = JSON.generate(federated)

      expect(serialized).not_to include("super-secret-staging-token")
      expect(federated["environments_queried"]).to eq(%w[local staging])
      expect(federated["projects"].size).to eq(1)
      expect(federated["projects"].first["environment"]).to eq("local")
      expect(federated["projects"].first["slug"]).to eq("web-app")
      expect(federated["errors"]).to contain_exactly(
        hash_including("environment" => "staging", "category" => "unreachable")
      )
    end

    it "reports transport_unavailable when remote_client is explicitly disabled" do
      disabled_dispatcher = described_class.new(config: config, remote_client: nil)
      federated = disabled_dispatcher.dispatch(:list_projects, environment: "all")

      expect(federated["projects"].size).to eq(1)
      expect(federated["errors"]).to contain_exactly(
        hash_including("environment" => "staging", "category" => "transport_unavailable")
      )
    end
  end
end
