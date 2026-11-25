require "rails/engine"
require_relative "configuration"
require_relative "routes"

module PersonalAppClient
  # The Rails side of the gem (v0.8.0+). Loaded automatically when the gem is
  # required inside a Rails app (Bundler.require). It is deliberately NOT an
  # isolated engine: its routes are drawn into the app by `personal_app_routes`
  # (no mount), and its views sit behind the app's, so an app overrides any
  # partial by putting a file at the same path under app/views/.
  #
  # What it does at boot:
  #   * time zone — config.time_zone defaults to PersonalAppClient::TIME_ZONE
  #     (set before the app's own config, so application.rb can still override);
  #   * rate limiting — RateLimit.install! with config.rate_limit /
  #     config.rate_limit_rules, unless the app already called install! itself
  #     or set config.rate_limit = false;
  #   * concerns — every PersonalAppClient::Rails::* concern, Mcp::BaseTool,
  #     Mcp::Registry, RateLimit and TestSupport autoload on first reference,
  #     so the apps' `require "personal_app_client/…"` lines can go;
  #   * routes — the `personal_app_routes` macro in config/routes.rb;
  #   * helpers — ShellHelper in every ActionController::Base view;
  #   * error reporting — when config.error_reporting.enabled? (production
  #     by default): see ErrorReporting;
  #   * content security policy — Csp.apply! (config.content_security_policy,
  #     report-only by default), unless the app set its own;
  #   * request log — one key=value line per request (config.request_log,
  #     production by default);
  #   * tailnet http — with config.assume_ssl, requests to a *.ts.net host stay
  #     plain http and skip force_ssl's redirect (TailnetSSL).
  class Engine < ::Rails::Engine
    engine_name "personal_app_client"

    config.before_configuration do |app|
      app.config.time_zone = PersonalAppClient::TIME_ZONE
    end

    # Routes are drawn after every initializer, so the macro is in place first.
    initializer "personal_app_client.tailnet_ssl", after: :load_config_initializers do |app|
      require_relative "tailnet_ssl"
      TailnetSSL.install!(app)
    end

    initializer "personal_app_client.routes" do
      ActionDispatch::Routing::Mapper.include(PersonalAppClient::Routes)
    end

    initializer "personal_app_client.helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper PersonalAppClient::ShellHelper
      end
    end

    initializer "personal_app_client.rate_limit", after: :load_config_initializers do |app|
      options = PersonalAppClient.config.rate_limit
      next if options == false || PersonalAppClient::RateLimit.installed?

      rules = PersonalAppClient.config.rate_limit_rules
      PersonalAppClient::RateLimit.install!(app: app, **options.to_h.transform_keys(&:to_sym), &rules)
    end

    initializer "personal_app_client.content_security_policy", after: :load_config_initializers do |app|
      PersonalAppClient::Csp.apply!(app)
    end

    initializer "personal_app_client.request_log", after: :load_config_initializers do
      PersonalAppClient::RequestLog.install! if PersonalAppClient.config.request_log?
    end

    initializer "personal_app_client.error_reporting", after: :load_config_initializers do
      PersonalAppClient::ErrorReporting.install! if PersonalAppClient.config.error_reporting.enabled?
    end

    # lib/tasks/personal_app_client.rake (personal_app:ds:snapshot) is loaded
    # by Rails::Engine itself, from the engine root's lib/tasks.
  end
end

module PersonalAppClient
  # The parent class of the engine's API controllers: config.api_base_controller
  # ("Api::BaseController", so they share the app's before_actions — fitness's
  # per-request zone, allow_browser, …), or PersonalAppClient::ApiController
  # when the app has no such class.
  def self.api_base_controller
    name = config.api_base_controller
    return name if name.is_a?(Class)

    name.to_s.safe_constantize || begin
      unless name.to_s == "Api::BaseController"
        raise NameError, "config.api_base_controller #{name.inspect} is not defined"
      end
      PersonalAppClient::ApiController
    end
  end
end
