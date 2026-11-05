require "active_support/core_ext/object/blank"
require_relative "errors"
require_relative "client"

module PersonalAppClient
  # Base class for the per-app wrappers around Client (BaseAppClient,
  # FitnessAppClient, MealplannerAppClient, UpkeepAppClient, …). Hoists what
  # every one of them repeated: build the Client from a Setting row plus
  # INTER_APP_SECRET, swallow a ConfigurationError into "unconfigured", and
  # the rescue-and-log shape around each call.
  #
  #     class FitnessAppClient < PersonalAppClient::AppClient
  #       app_client name: "fitness", setting: "fitness_app_url",
  #                  dev_url: "http://localhost:3000"
  #
  #       def blocks
  #         attempt("blocks", default: []) { |http| http.get("/api/blocks") }
  #       end
  #
  #       def goals!                      # raising variant for explicit actions
  #         http!.get("/api/goals")
  #       end
  #     end
  #
  # `app_client` options (inherited by subclasses, overridable per call):
  #   name          label used in log lines and error messages
  #   setting       Setting key holding the app's URL — or an Array of keys,
  #                 first present wins
  #   dev_url       fallback URL when the setting is blank; used ONLY in the
  #                 `fallback_envs`. In production a missing URL always means
  #                 "unconfigured" — never localhost
  #   fallback_envs environments where dev_url applies (default development, test)
  #   force_dev_url true → development always uses dev_url, ignoring the
  #                 setting (so a dev box holding a prod URL cannot sync to prod)
  #   open_timeout / read_timeout   passed to Client
  #
  # Subclasses written against the old hand-rolled shape keep working: the
  # Client still lives in @http, and `configured?` means the same thing.
  class AppClient
    DEFAULT_FALLBACK_ENVS = %w[development test].freeze

    class << self
      def app_client(**options)
        @app_client_options = app_client_options.merge(options).freeze
      end

      def app_client_options
        @app_client_options ||
          (superclass.respond_to?(:app_client_options) ? superclass.app_client_options : {})
      end
    end

    # All arguments are optional overrides, mainly for tests:
    #   base_url  skip the Setting lookup entirely
    #   http      inject a ready Client (or a double)
    #   secret / env / logger   default to INTER_APP_SECRET / Rails.env / Rails.logger
    def initialize(base_url: nil, http: nil, secret: nil, env: nil, logger: nil)
      @env = (env || default_env).to_s
      @logger = logger || default_logger
      @http = http || build_http(base_url, secret)
    rescue PersonalAppClient::ConfigurationError => e
      log_error(e.message)
      @http = nil
    end

    def configured?
      !@http.nil?
    end

    # The URL this client talks to, or nil when unconfigured.
    def base_url
      @http.respond_to?(:base_url) ? @http.base_url : nil
    end

    # Reachability check for a settings-page "test connection" button. Never
    # raises; returns a Hash ready to render as JSON:
    #
    #     { success: true,  status: 200, url: "http://…" }
    #     { success: false, status: 502, url: "http://…", error: "HTTP 502 …" }
    #     { success: false, url: "http://…", error: "Errno::ECONNREFUSED: …" }
    #     { success: false, error: "fitness URL not configured" }
    #
    # GETs `path` (default: Rails' /up health check) with the inter-app
    # secret, so it also proves the URL is not a Cloudflare-fronted one.
    def ping(path = "/up")
      return { success: false, error: "#{client_name} URL not configured" } unless configured?

      @http.get(path)
      { success: true, status: @http.respond_to?(:last_status) ? @http.last_status : nil, url: base_url }.compact
    rescue PersonalAppClient::ResponseError => e
      { success: false, status: e.status, url: base_url, error: e.message }
    rescue PersonalAppClient::Error => e
      { success: false, url: base_url, error: e.message }
    end

    private

    # The rescue-and-log shape every wrapper method had: return `default`
    # when unconfigured or when the call fails with a PersonalAppClient
    # error (logged), else the block's value. The block receives the Client.
    #
    #     def blocks = attempt("blocks", default: []) { |http| http.get("/api/blocks") }
    def attempt(label, default: nil, level: :error)
      return default unless configured?
      yield @http
    rescue PersonalAppClient::Error => e
      log("#{label}: #{e.message}", level)
      default
    end

    # The Client, or a ConfigurationError when unconfigured — for the
    # raising (`!`) variants behind explicit user actions.
    def http!
      raise PersonalAppClient::ConfigurationError, "#{client_name} app not configured" unless configured?
      @http
    end

    def build_http(base_url, secret)
      url = base_url.presence || resolve_base_url
      return nil if url.blank? # no URL → unconfigured, quietly

      options = self.class.app_client_options
      PersonalAppClient::Client.new(
        base_url: url,
        secret: secret || ENV.fetch("INTER_APP_SECRET", nil),
        env: @env,
        logger: @logger,
        **options.slice(:open_timeout, :read_timeout)
      )
    end

    def resolve_base_url
      options = self.class.app_client_options
      dev_url = options[:dev_url].presence
      return dev_url if dev_url && options[:force_dev_url] && @env == "development"

      url = Array(options[:setting]).lazy.map { |key| setting_value(key).presence }.find(&:itself)
      return url if url

      fallback_envs = Array(options.fetch(:fallback_envs, DEFAULT_FALLBACK_ENVS)).map(&:to_s)
      fallback_envs.include?(@env) ? dev_url : nil
    end

    # Where URLs come from. Every app has a `Setting.get(key)`; override for
    # anything else (ENV, credentials).
    def setting_value(key)
      defined?(::Setting) && ::Setting.respond_to?(:get) ? ::Setting.get(key) : nil
    end

    def client_name
      (self.class.app_client_options[:name] || self.class.name || "app").to_s
    end

    def default_env
      if defined?(::Rails) && ::Rails.respond_to?(:env)
        ::Rails.env
      else
        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      end
    end

    def default_logger
      defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
    end

    def log_error(message)
      log(message, :error)
    end

    def log(message, level = :error)
      @logger&.public_send(level, "#{self.class.name || client_name}: #{message}")
    end
  end
end
