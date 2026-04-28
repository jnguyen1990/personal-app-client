require "active_support/concern"
require "active_support/security_utils"
require "active_support/core_ext/object/blank"

module PersonalAppClient
  module Rails
    # Concern for Rails controllers exposing public-facing API endpoints
    # (MCP, bridge endpoints, etc) that authenticate via a shared API key.
    # Reads the key from an env var first, then optionally falls back to
    # Rails credentials. Accepts both `X-API-Key` and `Authorization: Bearer`
    # headers and uses constant-time comparison.
    #
    # Usage:
    #
    #     class Api::McpController < BaseController
    #       include PersonalAppClient::Rails::ApiKeyAuth
    #       # uses defaults: ENV["MCP_API_KEY"], credentials.mcp.api_key
    #     end
    #
    #     class Api::IcloudBridgeController < ApplicationController
    #       include PersonalAppClient::Rails::ApiKeyAuth
    #       api_key_config env: "BRIDGE_API_KEY", credential: [:bridge, :api_key]
    #     end
    module ApiKeyAuth
      extend ActiveSupport::Concern

      class_methods do
        attr_accessor :api_key_env_var, :api_key_credential_path

        # Configure which env var (and optional credentials path) the concern
        # should read for this controller. Call inside the controller class body.
        def api_key_config(env:, credential: nil)
          self.api_key_env_var = env
          self.api_key_credential_path = credential
        end
      end

      included do
        before_action :authenticate_api_key!
        self.api_key_env_var ||= "MCP_API_KEY"
        self.api_key_credential_path ||= [ :mcp, :api_key ]
      end

      private

      def authenticate_api_key!
        env_var = self.class.api_key_env_var
        cred_path = self.class.api_key_credential_path

        expected = ENV[env_var].presence
        expected ||= ::Rails.application.credentials.dig(*cred_path) if cred_path.is_a?(Array)

        if expected.blank?
          render json: { error: "#{env_var} not configured" },
                 status: :service_unavailable
          return
        end

        provided = request.headers["X-API-Key"].presence ||
                   request.headers["Authorization"].to_s.sub(/\ABearer\s+/i, "").presence

        return if provided.present? &&
                  provided.bytesize == expected.bytesize &&
                  ActiveSupport::SecurityUtils.secure_compare(provided, expected)

        render json: { error: "unauthorized" }, status: :unauthorized
      end
    end
  end
end
