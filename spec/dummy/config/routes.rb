Rails.application.routes.draw do
  personal_app_routes

  root "pages#home"
  get "goals", to: "pages#home"
  get "goals/:id", to: "pages#home"
  get "settings", to: "pages#settings"
  get "boom", to: "pages#boom"
  get "rendered-500", to: "pages#rendered_500"
  get "flash-demo", to: "pages#flash_demo"
  get "missing", to: "pages#missing"
end
