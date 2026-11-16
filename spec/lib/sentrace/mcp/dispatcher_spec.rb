require "rails_helper"

RSpec.describe Sentrace::Mcp::Dispatcher do
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

  subject(:dispatcher) { described_class.new(config: config) }

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
          "status" => "configured"
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

      expect(federated["environments_queried"]).to eq(%w[local staging])
      expect(federated["results"].size).to eq(1)
      expect(federated["results"].first["environment"]).to eq("local")
      expect(federated["errors"]).to contain_exactly(
        hash_including("environment" => "staging", "category" => "transport_unavailable")
      )
    end
  end
end
