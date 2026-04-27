require "active_support/concern"
require "active_support/security_utils"

module PersonalAppClient
  module Rails
    # Concern for Rails controllers exposing inter-app endpoints. Verifies
    # the X-App-Auth header against ENV["INTER_APP_SECRET"] using a
    # constant-time compare. Include in controllers whose routes are called
    # by sibling apps (not the routes the browser hits — those stay open
    # behind Cloudflare Access).
    module InterAppAuth
      extend ActiveSupport::Concern

      included do
        before_action :authenticate_inter_app!
      end

      private

      def authenticate_inter_app!
        expected = ENV["INTER_APP_SECRET"].to_s
        if expected.empty?
          render json: { error: "INTER_APP_SECRET not configured" },
                 status: :service_unavailable
          return
        end

        provided = request.headers["X-App-Auth"].to_s
        return if provided.bytesize == expected.bytesize &&
                  ActiveSupport::SecurityUtils.secure_compare(provided, expected)

        render json: { error: "unauthorized" }, status: :unauthorized
      end
    end
  end
end
