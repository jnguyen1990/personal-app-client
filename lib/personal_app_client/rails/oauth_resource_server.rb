require "active_support/concern"
require "active_support/security_utils"
require "active_support/core_ext/object/blank"
require "json"
require "net/http"
require "uri"
require "jwt"

module PersonalAppClient
  module Rails
    # Concern for Rails controllers exposing a remote MCP endpoint that must
    # authenticate to the OAuth 2.1 / MCP-authorization spec (so claude.ai's
    # account-connector flow can reach it). The controller is an OAuth
    # **Resource Server**: it validates a Bearer access token issued by the
    # cluster's Authorization Server (base), and on failure advertises where
    # the client should look for protected-resource metadata.
    #
    # Accepts EITHER:
    #   * a valid RS256 Bearer JWT (audience-bound to this app), OR
    #   * the legacy shared `X-API-Key` / `Authorization: Bearer <shared>`
    #     (kept so inter-app calls and the Claude Code header stopgap keep
    #     working during migration — disable by leaving MCP_API_KEY unset).
    #
    # Configuration (env, with per-controller overrides via oauth_rs_config):
    #   MCP_OAUTH_ISSUER          expected `iss` (base's AS URL)
    #   MCP_OAUTH_JWKS_URL        where to fetch signing keys (JWKS)
    #   MCP_RESOURCE_URL          this app's canonical resource id; must appear
    #                             in the token `aud` (or RFC 8707 `resource`)
    #   MCP_PR_METADATA_URL       this app's /.well-known/oauth-protected-resource
    #   MCP_API_KEY               legacy shared key (optional fallback)
    #
    # On success exposes `current_mcp_subject` (the token `sub`).
    module OauthResourceServer
      extend ActiveSupport::Concern

      JWKS_TTL = 300 # seconds; signing keys are cached this long

      class_methods do
        attr_accessor :oauth_rs_issuer_env, :oauth_rs_jwks_env,
                      :oauth_rs_resource_env, :oauth_rs_metadata_env,
                      :oauth_rs_shared_key_env

        # Override which env vars this controller reads. Call in the class body.
        def oauth_rs_config(issuer: nil, jwks: nil, resource: nil, metadata: nil, shared_key: nil)
          self.oauth_rs_issuer_env   = issuer   if issuer
          self.oauth_rs_jwks_env     = jwks     if jwks
          self.oauth_rs_resource_env = resource if resource
          self.oauth_rs_metadata_env = metadata if metadata
          self.oauth_rs_shared_key_env = shared_key if shared_key
        end
      end

      included do
        before_action :authenticate_mcp!
        self.oauth_rs_issuer_env     ||= "MCP_OAUTH_ISSUER"
        self.oauth_rs_jwks_env       ||= "MCP_OAUTH_JWKS_URL"
        self.oauth_rs_resource_env   ||= "MCP_RESOURCE_URL"
        self.oauth_rs_metadata_env   ||= "MCP_PR_METADATA_URL"
        self.oauth_rs_shared_key_env ||= "MCP_API_KEY"
      end

      # The validated token subject after a successful bearer-JWT auth, or
      # :shared_key when the legacy key was used. nil before authentication.
      attr_reader :current_mcp_subject

      private

      def authenticate_mcp!
        token = bearer_token

        if token && (claims = verify_access_token(token))
          @current_mcp_subject = claims["sub"]
          return
        end

        if shared_key_valid?(token)
          @current_mcp_subject = :shared_key
          return
        end

        unauthorized!
      end

      # ---- bearer JWT path ------------------------------------------------

      def verify_access_token(token)
        issuer   = ENV[self.class.oauth_rs_issuer_env].presence
        resource = ENV[self.class.oauth_rs_resource_env].presence
        return nil if issuer.blank? || resource.blank?

        keys = jwks_keys
        return nil if keys.nil?

        payload, = JWT.decode(
          token, nil, true,
          algorithms: [ "RS256" ],
          jwks: keys,
          iss: issuer,
          verify_iss: true,
          verify_expiration: true
        )

        return nil unless audience_matches?(payload, resource)
        payload
      rescue JWT::DecodeError
        nil
      end

      # Accept either `aud` (string or array) or RFC 8707 `resource`.
      def audience_matches?(payload, resource)
        auds = Array(payload["aud"]) + Array(payload["resource"])
        auds.include?(resource)
      end

      # Fetch + cache the AS signing keys. Returns a JWT::JWK::Set or nil.
      def jwks_keys
        url = ENV[self.class.oauth_rs_jwks_env].presence
        return nil if url.blank?

        cached = self.class.instance_variable_get(:@oauth_rs_jwks_cache)
        if cached && cached[:url] == url && (monotonic - cached[:at]) < JWKS_TTL
          return cached[:set]
        end

        body = http_get_json(url)
        return cached&.dig(:set) if body.nil? # network blip → reuse stale keys
        set = JWT::JWK::Set.new(body)
        self.class.instance_variable_set(:@oauth_rs_jwks_cache,
                                         { url: url, at: monotonic, set: set })
        set
      rescue StandardError
        nil
      end

      def http_get_json(url)
        uri = URI.parse(url)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                              open_timeout: 3, read_timeout: 3) do |http|
          http.get(uri.request_uri)
        end
        return nil unless res.is_a?(Net::HTTPSuccess)
        JSON.parse(res.body)
      rescue StandardError
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # ---- legacy shared-key fallback ------------------------------------

      def shared_key_valid?(provided)
        expected = ENV[self.class.oauth_rs_shared_key_env].presence
        return false if expected.blank?
        provided ||= request.headers["X-API-Key"].presence
        return false if provided.blank?
        provided.bytesize == expected.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(provided, expected)
      end

      # ---- shared helpers -------------------------------------------------

      def bearer_token
        header = request.headers["Authorization"].to_s
        return nil unless header =~ /\ABearer\s+(.+)\z/i
        Regexp.last_match(1)
      end

      def unauthorized!
        metadata = ENV[self.class.oauth_rs_metadata_env].presence
        if metadata
          response.set_header(
            "WWW-Authenticate",
            %(Bearer resource_metadata="#{metadata}")
          )
        end
        render json: { error: "unauthorized" }, status: :unauthorized
      end
    end
  end
end
