module Api
  class BaseController < ApplicationController
    skip_forgery_protection
    include PersonalAppClient::Rails::InterAppAuthOptional
    include PersonalAppClient::Rails::ApiErrors

    # Proves the engine's default controllers inherit the app's API base.
    before_action { response.headers["X-Dummy-Api-Base"] = "1" }
  end
end
