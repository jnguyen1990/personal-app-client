require "active_support/concern"
require "active_support/security_utils"

module PersonalAppClient
  module Rails
    # Concern for controllers whose routes are called by BOTH browsers
    # (no X-App-Auth header — auth handled out-of-band, e.g. Cloudflare
    # Access) AND sibling apps (header present, must match).
    #
    # Header absent  → allow (defer to whatever protects browser surface).
    # Header present → INTER_APP_SECRET must be configured and match,
    #                  else 503 (unconfigured) or 401 (mismatch).
    module InterAppAuthOptional
      extend ActiveSupport::Concern

      included do
        before_action :verify_inter_app_secret_if_present!
      end

      private

      def verify_inter_app_secret_if_present!
        provided = request.headers["X-App-Auth"].to_s
        return if provided.empty?

        expected = ENV["INTER_APP_SECRET"].to_s
        if expected.empty?
          render json: { error: "INTER_APP_SECRET not configured" },
                 status: :service_unavailable
          return
        end

        return if provided.bytesize == expected.bytesize &&
                  ActiveSupport::SecurityUtils.secure_compare(provided, expected)

        render json: { error: "invalid X-App-Auth" }, status: :unauthorized
      end
    end
  end
end
