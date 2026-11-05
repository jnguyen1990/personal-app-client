module PersonalAppClient
  # One-call Rack::Attack setup for the apps' config/initializers/rack_attack.rb:
  #
  #     require "personal_app_client/rate_limit"
  #
  #     PersonalAppClient::RateLimit.install!
  #
  # That gives the throttle budgeter and fitness already had — 120 requests a
  # minute per IP on /api/ — and a JSON 429 with Retry-After. App-specific
  # rules go in the block, which receives Rack::Attack:
  #
  #     PersonalAppClient::RateLimit.install! do |attack|
  #       attack.throttle("icloud-bridge/ip", limit: 60, period: 60) do |req|
  #         req.ip if req.path.start_with?("/api/icloud-bridge/")
  #       end
  #     end
  #
  # Options: limit: / period: / path_prefix: tune the default throttle;
  # api_throttle: false drops it (block rules only); app: is the Rails
  # application (default Rails.application).
  #
  # Safe to call more than once: rules are re-registered under the same
  # names and the middleware is inserted a single time. When rack-attack was
  # already loaded with Rails (it is in the app's Gemfile), its own railtie
  # has inserted the middleware and this adds nothing.
  module RateLimit
    DEFAULT_LIMIT = 120
    DEFAULT_PERIOD = 60
    DEFAULT_PATH_PREFIX = "/api/".freeze
    THROTTLE_NAME = "api/ip".freeze

    class << self
      def install!(app: nil, limit: DEFAULT_LIMIT, period: DEFAULT_PERIOD,
                   path_prefix: DEFAULT_PATH_PREFIX, api_throttle: true)
        # Checked BEFORE the require: a railtie defined this late (from inside
        # an initializer) is never run by Rails, so only one that was already
        # loaded counts as having inserted the middleware.
        railtie_loaded = defined?(::Rack::Attack::Railtie) ? true : false
        require "rack/attack"

        if api_throttle
          ::Rack::Attack.throttle(THROTTLE_NAME, limit: limit, period: period) do |req|
            req.ip if req.path.start_with?(path_prefix)
          end
        end

        ::Rack::Attack.throttled_responder = method(:throttled_response)

        yield ::Rack::Attack if block_given?

        insert_middleware(app, railtie_loaded)
        ::Rack::Attack
      end

      # 429 with the period of the rule that tripped as Retry-After.
      def throttled_response(request)
        match = request.env["rack.attack.match_data"] || {}
        retry_after = (match[:period] || DEFAULT_PERIOD).to_i
        [
          429,
          { "content-type" => "application/json", "retry-after" => retry_after.to_s },
          [ %({"error":"rate limit exceeded"}) ]
        ]
      end

      private

      def insert_middleware(app, railtie_loaded)
        return if @installed || railtie_loaded

        app ||= ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application)
        return if app.nil? # plain Rack: the caller mounts Rack::Attack itself

        app.config.middleware.use ::Rack::Attack
        @installed = true
      end
    end
  end
end
