Sentrace::Engine.routes.draw do
  post "/api/:project_id/envelope", to: "ingestion#envelope"
  match "/mcp", to: "mcp#handle", via: [ :post, :get, :delete ]

  namespace :internal do
    resources :projects
    resources :issues, only: [ :index, :show, :update ]
    resources :events, only: [ :index, :show ]
    resource :stats, only: [ :show ], controller: "stats"
  end
end
