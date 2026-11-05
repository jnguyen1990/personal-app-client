require "active_support/concern"

module PersonalAppClient
  module Rails
    # Shared JSON error responses for API controllers, so a missing record or
    # a missing required param is a clean 404 / 400 instead of an HTML error
    # page (or a 500) that the calling app cannot parse.
    #
    #     class Api::BaseController < ApplicationController
    #       include PersonalAppClient::Rails::ApiErrors
    #     end
    #
    #   ActiveRecord::RecordNotFound         → 404 { "error": "not found" }
    #   ActionController::ParameterMissing   → 400 { "error": "<message>" }
    #
    # A controller's own rescue_from for either class, declared after the
    # include, takes precedence (Rails checks handlers last-declared first).
    module ApiErrors
      extend ActiveSupport::Concern

      included do
        # Class names as strings: resolved when an exception is raised, so
        # requiring this file does not load ActiveRecord or ActionController.
        rescue_from "ActiveRecord::RecordNotFound", with: :render_api_not_found
        rescue_from "ActionController::ParameterMissing", with: :render_api_bad_request
      end

      private

      def render_api_not_found(_error = nil)
        render json: { error: "not found" }, status: :not_found
      end

      def render_api_bad_request(error)
        render json: { error: error.message }, status: :bad_request
      end
    end
  end
end
