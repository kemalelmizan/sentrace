Sentrace::Engine.routes.draw do
  post "/api/:project_id/envelope", to: "ingestion#envelope"
  match "/mcp", to: "mcp#handle", via: [ :post, :get, :delete ]
end
