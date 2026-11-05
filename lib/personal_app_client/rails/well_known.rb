require "active_support/concern"
require "active_support/core_ext/object/blank"

module PersonalAppClient
  module Rails
    # RFC 9728 protected-resource metadata, so an MCP/OAuth client can
    # discover that this app's /api/mcp is guarded by the cluster
    # Authorization Server (base). Serve it on a Cloudflare Access *bypass*
    # path — machine clients can't do OTP.
    #
    #     # app/controllers/well_known_controller.rb
    #     class WellKnownController < ActionController::API
    #       include PersonalAppClient::Rails::WellKnown
    #     end
    #
    #     # config/routes.rb
    #     get "/.well-known/oauth-protected-resource", to: "well_known#protected_resource"
    #
    # Reads (per request):
    #   MCP_OAUTH_ISSUER   the Authorization Server (default https://base.joenguyen.ca)
    #   MCP_RESOURCE_URL   this app's resource id (default <request base>/api/mcp)
    module WellKnown
      extend ActiveSupport::Concern

      DEFAULT_ISSUER = "https://base.joenguyen.ca".freeze

      def protected_resource
        issuer = ENV["MCP_OAUTH_ISSUER"].presence || DEFAULT_ISSUER
        resource = ENV["MCP_RESOURCE_URL"].presence || "#{request.base_url}/api/mcp"
        render json: {
          resource: resource,
          authorization_servers: [ issuer ],
          scopes_supported: [ "mcp" ],
          bearer_methods_supported: [ "header" ]
        }
      end
    end
  end
end
