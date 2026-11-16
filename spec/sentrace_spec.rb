require "rails_helper"

RSpec.describe Sentrace do
  it "defines a gem version" do
    expect(Sentrace::VERSION).not_to be_nil
  end

  it "isolates the Rails engine namespace with sentrace_ table prefix" do
    expect(Sentrace::Engine.isolated?).to be(true)
    expect(Sentrace.table_name_prefix).to eq("sentrace_")
  end

  it "declares Rails >= 6.1, pg >= 1.4, Ruby >= 3.2, and mcp ~> 1.0 in sentrace.gemspec" do
    gemspec = Gem::Specification.load(File.expand_path("../sentrace.gemspec", __dir__))
    deps = gemspec.runtime_dependencies.index_by(&:name)

    expect(gemspec.required_ruby_version).to eq(Gem::Requirement.new(">= 3.2.0"))
    expect(deps.fetch("rails").requirement).to eq(Gem::Requirement.new(">= 6.1", "< 9.0"))
    expect(deps.fetch("pg").requirement).to eq(Gem::Requirement.new(">= 1.4", "< 2.0"))
    expect(deps.fetch("mcp").requirement).to eq(Gem::Requirement.new("~> 1.0"))
  end
end
