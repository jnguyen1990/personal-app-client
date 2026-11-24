require "json"
require "net/http"
require "uri"

module PersonalAppClient
  class Client
    DEFAULT_GUARDED_DOMAINS = [/\.joenguyen\.ca\z/].freeze
    # Failures before the request left this machine: the connection was never
    # made, so a retry cannot perform anything twice — retried for every method.
    CONNECT_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      Net::OpenTimeout
    ].freeze
    # Failures after the request may have reached the server (the connection
    # dropped mid-exchange). Retried only for idempotent requests: GET, PUT and
    # DELETE always, POST and PATCH only when the caller passes
    # `idempotent: true` (an upsert keyed on source_app + external_id, say) —
    # a create-style call retried here could be performed twice.
    DROPPED_ERRORS = [
      Errno::ECONNRESET,
      EOFError
    ].freeze
    RETRYABLE_NETWORK_ERRORS = (CONNECT_ERRORS + DROPPED_ERRORS).freeze
    IDEMPOTENT_METHODS = %i[get put delete].freeze

    attr_reader :base_url

    # HTTP status of the most recent response (Integer), or nil before the
    # first request and after one that never got a response.
    attr_reader :last_status

    def initialize(base_url:, secret: nil, env: nil,
                   guarded_domains: DEFAULT_GUARDED_DOMAINS,
                   open_timeout: 5, read_timeout: 10,
                   logger: nil)
      @base_url = base_url
      @secret = secret
      @env = (env || ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development").to_s
      @guarded_domains = Array(guarded_domains)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @logger = logger
      validate_url!
    end

    def get(path, query = nil)
      request(:get, path, query: query)
    end

    # `idempotent: true` lets a dropped connection be retried (see
    # DROPPED_ERRORS); only pass it when performing the call twice is harmless.
    def post(path, body = nil, idempotent: false)
      request(:post, path, body: body, idempotent: idempotent)
    end

    def put(path, body = nil)
      request(:put, path, body: body)
    end

    def patch(path, body = nil, idempotent: false)
      request(:patch, path, body: body, idempotent: idempotent)
    end

    def delete(path)
      request(:delete, path)
    end

    private

    def validate_url!
      raise ConfigurationError, "base_url is required" if @base_url.nil? || @base_url.to_s.strip.empty?

      uri = URI(@base_url)
      raise ConfigurationError, "base_url must be http(s): #{@base_url}" unless %w[http https].include?(uri.scheme)
      raise ConfigurationError, "base_url must include host: #{@base_url}" if uri.host.to_s.empty?

      return unless production? && guarded_host?(uri.host)

      raise ConfigurationError,
            "Refusing to use public/proxied URL #{@base_url} for inter-app calls. " \
            "Cloudflare Access intercepts these with a 302 challenge and the request " \
            "fails silently. Use the LAN/Tailscale URL instead " \
            "(e.g. http://<app>.<tailnet>.ts.net:<port>)."
    end

    def production?
      @env == "production"
    end

    def guarded_host?(host)
      return false if host.nil?
      @guarded_domains.any? { |pattern| pattern.match?(host) }
    end

    def request(method, path, query: nil, body: nil, idempotent: false)
      @last_status = nil
      uri = build_uri(path, query)
      req = build_request(method, uri, body)
      response = perform(uri, req, idempotent: idempotent || IDEMPOTENT_METHODS.include?(method))
      handle(response, uri)
    end

    def build_uri(path, query)
      uri = URI.join(@base_url.sub(%r{/\z}, "") + "/", path.sub(%r{\A/}, ""))
      if query.is_a?(Hash) && !query.empty?
        merged = URI.decode_www_form(uri.query.to_s) + query.map { |k, v| [k.to_s, v.to_s] }
        uri.query = URI.encode_www_form(merged)
      end
      uri
    end

    def build_request(method, uri, body)
      klass = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        put: Net::HTTP::Put,
        patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete
      }.fetch(method)

      req = klass.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Accept"] = "application/json"
      req["X-App-Auth"] = @secret if @secret && !@secret.empty?
      req.body = body.to_json if body && %i[post put patch].include?(method)
      req
    end

    def perform(uri, req, idempotent:)
      attempts = 0
      begin
        attempts += 1
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        # Net::HTTP itself silently re-sends an idempotent request once on a
        # dropped connection; keep that decision here, in one place.
        http.max_retries = 0
        http.request(req)
      rescue *RETRYABLE_NETWORK_ERRORS => e
        if attempts < 2 && (idempotent || CONNECT_ERRORS.any? { |k| e.is_a?(k) })
          log("retry after #{e.class}: #{e.message}")
          retry
        end
        raise ConnectionError, "#{e.class}: #{e.message} (url=#{uri})"
      rescue Net::ReadTimeout => e
        raise TimeoutError, "read timeout after #{@read_timeout}s (url=#{uri}): #{e.message}"
      end
    end

    def handle(response, uri)
      code = response.code.to_i
      @last_status = code
      case code
      when 200..299
        parse_body(response)
      when 300..399
        raise ResponseError.new(
          redirect_hint(response, uri),
          status: code, body: response.body, url: uri.to_s
        )
      else
        raise ResponseError.new(
          "HTTP #{code} from #{uri} — #{truncate(response.body)}",
          status: code, body: response.body, url: uri.to_s
        )
      end
    end

    def redirect_hint(response, uri)
      location = response["location"].to_s
      if location.include?("cloudflareaccess.com")
        "HTTP #{response.code} from #{uri} — Cloudflare Access challenge. " \
        "This URL is public/proxied; configure inter-app calls to use the " \
        "Tailscale or LAN URL instead."
      else
        "HTTP #{response.code} redirect from #{uri} -> #{location}"
      end
    end

    def parse_body(response)
      return nil if response.body.nil? || response.body.empty?
      JSON.parse(response.body)
    rescue JSON::ParserError
      response.body
    end

    def truncate(str, max = 200)
      return "" if str.nil?
      str.length > max ? "#{str[0, max]}…" : str
    end

    def log(message)
      @logger&.warn("[PersonalAppClient] #{message}")
    end
  end
end
