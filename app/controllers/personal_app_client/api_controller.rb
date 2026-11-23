module PersonalAppClient
  # Parent of the engine's API controllers when the app has no
  # Api::BaseController (config.api_base_controller): the same shape the
  # apps' Api::BaseController has — no CSRF on JSON endpoints, X-App-Auth
  # checked when present, JSON 404 / 400.
  class ApiController < ActionController::Base
    skip_forgery_protection
    include PersonalAppClient::Rails::InterAppAuthOptional
    include PersonalAppClient::Rails::ApiErrors
  end
end
