require "active_support/concern"
require "active_support/security_utils"
require "active_support/core_ext/class/attribute"
require_relative "../cloudflare_access"

module PersonalAppClient
  module Rails
    # Concern for operator-only actions — backup/restore, "wipe all data" and
    # anything else that should never run for an anonymous tailnet device.
    #
    # A request passes when EITHER:
    #   * `X-App-Auth` matches ENV["INTER_APP_SECRET"] (constant-time compare)
    #     — machine callers, e.g. the Mac mini's nightly backup pull, OR
    #   * it carries a valid Cloudflare Access JWT — the settings-page buttons
    #     in a browser. Read from the `Cf-Access-Jwt-Assertion` header Access
    #     adds at the edge, else the `CF_Authorization` cookie the browser
    #     holds (the only copy present on paths with an Access *bypass*
    #     policy, which is how the apps expose /api/). Either way the token is
    #     verified by CloudflareAccess — signature, issuer, expiry.
    #
    # Anything else gets 401 `{ "error": "unauthorized" }`. Note what is NOT
    # accepted: `Cf-Access-Authenticated-User-Email` is a plain header any
    # tailnet device can forge.
    #
    # Enforced only in production, so app test suites and local dev keep
    # working without credentials. Override per controller with
    # `operator_auth enforce: true` (or false), or process-wide with
    # ENV["OPERATOR_AUTH_ENFORCE"]=1 — the ENV switch can only turn
    # enforcement ON, never off.
    #
    #     class Api::SettingsController < BaseController
    #       include PersonalAppClient::Rails::OperatorAuth
    #       operator_auth only: [ :wipe_data ]
    #     end
    #
    # Without an `operator_auth` call every action is guarded. On success
    # `current_operator` is :inter_app or the Access token's email/sub.
    module OperatorAuth
      extend ActiveSupport::Concern

      included do
        class_attribute :operator_auth_enforce, instance_writer: false, default: nil
        before_action :authenticate_operator!
      end

      class_methods do
        # Scope the guard (`only:` / `except:`, as before_action takes them)
        # and/or pin enforcement regardless of environment.
        def operator_auth(only: nil, except: nil, enforce: :unset)
          self.operator_auth_enforce = enforce unless enforce == :unset
          return if only.nil? && except.nil?

          skip_before_action :authenticate_operator!, raise: false
          before_action :authenticate_operator!, **{ only: only, except: except }.compact
        end
      end

      # Who passed the guard: :inter_app, the Access identity (String), or
      # nil when unauthenticated / not enforced.
      attr_reader :current_operator

      private

      def authenticate_operator!
        return unless operator_auth_enforced?

        if operator_secret_valid?
          @current_operator = :inter_app
          return
        end

        if (claims = PersonalAppClient::CloudflareAccess.verify(operator_access_token))
          @current_operator = claims["email"] || claims["sub"] || :cloudflare_access
          return
        end

        render json: { error: "unauthorized" }, status: :unauthorized
      end

      def operator_auth_enforced?
        return true if %w[1 true yes on].include?(ENV["OPERATOR_AUTH_ENFORCE"].to_s.strip.downcase)

        setting = self.class.operator_auth_enforce
        return setting unless setting.nil?
        ::Rails.env.production?
      end

      def operator_secret_valid?
        expected = ENV["INTER_APP_SECRET"].to_s
        provided = request.headers["X-App-Auth"].to_s
        return false if expected.empty? || provided.empty?
        provided.bytesize == expected.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(provided, expected)
      end

      def operator_access_token
        token = request.headers["Cf-Access-Jwt-Assertion"].to_s
        return token unless token.empty?
        request.respond_to?(:cookies) ? request.cookies["CF_Authorization"] : nil
      end
    end
  end
end
