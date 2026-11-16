Rails.application.routes.draw do
  mount Sentrace::Engine => "/sentrace"
end
