require "action_dispatch"
require "action_dispatch/middleware/assume_ssl"

module PersonalAppClient
  # Every app serves two front doors: the public https://<app>.joenguyen.ca through
  # the Cloudflare Tunnel (TLS ends at Cloudflare, so the app sees plain http) and
  # the tailnet http://<app>.tail5ece07.ts.net:3000 (plain http end to end). Rails'
  # `config.assume_ssl` marks every request https, so on the tailnet each redirect
  # pointed at https://…ts.net:3000, which nothing serves (base's /jobs → /status,
  # 2026-11-25). TailnetSSL keeps assume_ssl for the public door and leaves tailnet
  # requests as the plain http they are; `force_ssl` then skips its https redirect
  # for them (cookies are flagged Secure and HSTS is sent only on https requests,
  # so neither changes for the public door).
  module TailnetSSL
    SUFFIX = ".ts.net".freeze

    def self.tailnet?(env_or_request)
      request = env_or_request.respond_to?(:host) ? env_or_request : ::Rack::Request.new(env_or_request)
      host = request.host
      host.to_s.downcase.end_with?(SUFFIX)
    end

    # ActionDispatch::AssumeSSL, except for tailnet hosts.
    class AssumeSSL < ::ActionDispatch::AssumeSSL
      def call(env)
        return @app.call(env) if TailnetSSL.tailnet?(env)

        super
      end
    end

    # Swap the middleware and exempt tailnet hosts from force_ssl's redirect, keeping
    # any exclude the app already set. A no-op unless the app assumes SSL.
    def self.install!(app)
      config = app.config
      return unless config.assume_ssl

      config.middleware.swap ::ActionDispatch::AssumeSSL, AssumeSSL
      return unless config.force_ssl

      options = (config.ssl_options ||= {})
      return if options[:redirect] == false

      redirect = options[:redirect].is_a?(Hash) ? options[:redirect].dup : {}
      prior = redirect[:exclude]
      redirect[:exclude] = ->(request) { TailnetSSL.tailnet?(request) || (prior ? prior.call(request) : false) }
      options[:redirect] = redirect
    end
  end
end
