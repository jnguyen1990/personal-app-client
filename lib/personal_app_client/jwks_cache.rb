require "json"
require "net/http"
require "uri"
require "jwt"

module PersonalAppClient
  # Fetches and caches JSON Web Key Sets by URL. Shared by every verifier in
  # this gem that checks RS256 tokens against a remote issuer (the cluster
  # Authorization Server via OauthResourceServer, Cloudflare Access via
  # CloudflareAccess) so they agree on caching and failure behaviour:
  #
  #   * keys are cached for TTL seconds, per URL, process-wide
  #   * a failed refresh (network blip, non-2xx, bad JSON) reuses the stale
  #     keys rather than locking every caller out until the issuer is back
  #   * nil only when there has never been a successful fetch for that URL
  module JwksCache
    TTL = 300 # seconds

    @cache = {}
    @mutex = Mutex.new

    class << self
      # Returns a JWT::JWK::Set, or nil.
      def fetch(url)
        return nil if url.nil? || url.to_s.empty?

        cached = @mutex.synchronize { @cache[url] }
        return cached[:set] if cached && (monotonic - cached[:at]) < TTL

        body = http_get_json(url)
        return cached && cached[:set] if body.nil? # network blip → reuse stale keys

        set = JWT::JWK::Set.new(body)
        @mutex.synchronize { @cache[url] = { at: monotonic, set: set } }
        set
      rescue StandardError
        cached && cached[:set]
      end

      # Drop one URL's keys, or everything. Mostly for specs.
      def clear(url = nil)
        @mutex.synchronize { url ? @cache.delete(url) : @cache.clear }
        nil
      end

      private

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
    end
  end
end
