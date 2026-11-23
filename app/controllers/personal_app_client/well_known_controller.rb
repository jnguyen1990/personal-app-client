module PersonalAppClient
  # Default GET /.well-known/oauth-protected-resource (RFC 9728, WellKnown).
  # Served on a Cloudflare Access bypass path — machine clients can't do OTP.
  # base, the Authorization Server, routes it to its own
  # Oauth::MetadataController: `well_known: "oauth/metadata"`.
  class WellKnownController < ActionController::API
    include PersonalAppClient::Rails::WellKnown
  end
end
