require_relative "lib/sentrace/version"

Gem::Specification.new do |spec|
  spec.name        = "sentrace"
  spec.version     = Sentrace::VERSION
  spec.authors     = [ "Kemal Elmizan" ]
  spec.summary     = "Sentry-compatible error tracking for Rails, with a federated MCP interface."
  spec.description = "Self-hosted, PostgreSQL-backed Sentry envelope ingestion and issue grouping for Ruby on Rails applications, exposed via federated Model Context Protocol (MCP) transports."
  spec.homepage    = "https://github.com/kemalelmizan/sentrace"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "LICENSE.txt", "Rakefile", "README.md"]
  end

  spec.add_dependency "mcp", "~> 1.0"
  spec.add_dependency "pg", ">= 1.5"
  spec.add_dependency "rails", ">= 7.1"
end
