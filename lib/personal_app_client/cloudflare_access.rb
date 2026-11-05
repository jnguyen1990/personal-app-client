require "jwt"
require_relative "jwks_cache"

module PersonalAppClient
  # Verifies the JWT Cloudflare Access attaches to every request it lets
  # through (`Cf-Access-Jwt-Assertion` header, `CF_Authorization` cookie).
  #
  # This is the ONLY trustworthy evidence that a request came through
  # Access. `Cf-Access-Authenticated-User-Email` is a plain header: any
  # device on the tailnet can reach the app directly and set it to whatever
  # it likes, so it must never be trusted on its own.
  #
  # Configuration (read lazily, per call):
  #   CF_ACCESS_TEAM_DOMAIN  team domain (default jnguyen.cloudflareaccess.com)
  #   CF_ACCESS_AUD          optional Access application AUD tag; when set the
  #                          token must carry it in `aud`, which pins the token
  #                          to THIS app rather than any app in the team
  module CloudflareAccess
    DEFAULT_TEAM_DOMAIN = "jnguyen.cloudflareaccess.com".freeze

    module_function

    # Returns the token's claims Hash when it is a valid, unexpired RS256
    # token signed by the team's current keys, else nil. Never raises.
    def verify(token)
      return nil if token.nil? || token.to_s.strip.empty?

      keys = JwksCache.fetch(certs_url)
      return nil if keys.nil?

      payload, = JWT.decode(
        token.to_s, nil, true,
        algorithms: [ "RS256" ],
        jwks: keys,
        iss: issuer,
        verify_iss: true,
        verify_expiration: true
      )

      expected_aud = ENV["CF_ACCESS_AUD"].to_s.strip
      return nil unless expected_aud.empty? || Array(payload["aud"]).include?(expected_aud)
      payload
    rescue JWT::DecodeError
      nil
    rescue StandardError
      nil
    end

    def team_domain
      domain = ENV["CF_ACCESS_TEAM_DOMAIN"].to_s.strip
      domain = DEFAULT_TEAM_DOMAIN if domain.empty?
      domain.sub(%r{\Ahttps?://}, "").sub(%r{/+\z}, "")
    end

    def issuer
      "https://#{team_domain}"
    end

    def certs_url
      "#{issuer}/cdn-cgi/access/certs"
    end
  end
end
