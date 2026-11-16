Sentrace::Engine.routes.draw do
  post "/api/:project_id/envelope", to: "ingestion#envelope"
end
