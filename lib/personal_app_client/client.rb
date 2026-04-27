require "json"
require "net/http"
require "uri"

module PersonalAppClient
  class Client
    DEFAULT_GUARDED_DOMAINS = [/\.joenguyen\.ca\z/].freeze
    RETRYABLE_NETWORK_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      EOFError,
      Net::OpenTimeout
    ].freeze

    attr_reader :base_url

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

    def post(path, body = nil)
      request(:post, path, body: body)
    end

    def put(path, body = nil)
      request(:put, path, body: body)
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

    def request(method, path, query: nil, body: nil)
      uri = build_uri(path, query)
      req = build_request(method, uri, body)
      response = perform(uri, req)
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
        delete: Net::HTTP::Delete
      }.fetch(method)

      req = klass.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Accept"] = "application/json"
      req["X-App-Auth"] = @secret if @secret && !@secret.empty?
      req.body = body.to_json if body && %i[post put].include?(method)
      req
    end

    def perform(uri, req)
      attempts = 0
      begin
        attempts += 1
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.request(req)
      rescue *RETRYABLE_NETWORK_ERRORS => e
        if attempts < 2
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
