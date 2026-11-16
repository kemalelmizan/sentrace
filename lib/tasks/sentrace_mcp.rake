namespace :sentrace do
  desc "Run the Sentrace Model Context Protocol (MCP) server over stdio"
  task mcp: :environment do
    Sentrace::Mcp::StdioRunner.run
  end
end
