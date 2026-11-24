require "json"
require "uri"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"

module PersonalAppClient
  # Per-app settings for the engine (shell, default controllers, Railtie).
  # Set them once, in config/initializers/personal_app.rb:
  #
  #     PersonalAppClient.configure do |app|
  #       app.app_id   = "budgeter"            # data-app, <title> suffix, default <h1>
  #       app.app_name = "Budgeter"            # sidebar brand, PWA name
  #       app.nav_items = [
  #         { path: "/",         label: "dashboard", ico: "grid",    key: "1" },
  #         { path: "/budget",   label: "budget",    ico: "pie-chart", key: "2" },
  #         { path: "/settings", label: "settings",  ico: "sliders", key: "," }
  #       ]
  #     end
  #
  # Every key has a default that reproduces what most of the apps did before
  # the engine existed; the README lists them all.
  class Configuration
    DEFAULT_DS_BASE = "https://design-system.joenguyen.ca".freeze
    # Loaded by every app, in this order: shared-core first (synchronously, it
    # boots the theme before first paint), then ds_scripts, then modal-keys.
    CORE_DS_SCRIPTS = %w[shared-core].freeze
    TAIL_DS_SCRIPTS = %w[modal-keys].freeze
    DEFERRED_DS_SCRIPTS = %w[apps-launcher].freeze
    # Every file the design system serves to apps — what `personal_app:ds:snapshot`
    # copies into public/ds/ for the offline fallback.
    DS_FILES = %w[design-system.css shared-core.js modal-keys.js apps-launcher.js
                  session-render.js goal-render.js].freeze

    # Page background (--sheet) in each theme since the flat v4.4 surface
    # model: white light, slate-1 dark.
    DEFAULT_THEME_COLORS = { light: "#ffffff", dark: "#111113" }.freeze

    # --- identity --------------------------------------------------------
    attr_writer :app_id, :app_name

    # --- shell -----------------------------------------------------------
    # nav_items: Array of Hashes (or a Proc returning one, evaluated in the
    # view). Keys: path, label, ico, key, and optionally `active:` (:exact —
    # the default —, :prefix, a Regexp, or a Proc taking the request path) and
    # `prefixes:` (extra path prefixes that also mark the item active).
    attr_accessor :nav_items
    # Extra design-system scripts loaded after shared-core.js, before
    # modal-keys.js (base and fitness: %w[session-render goal-render]).
    attr_accessor :ds_scripts
    # :inline (title, badge and actions on one row, subtitle under it — five
    # apps) or :split (title + subtitle stacked on the left, actions on the
    # right — base).
    attr_accessor :header_style
    # Tag for the page subtitle: :p (most apps) or :span (upkeep, postings).
    attr_accessor :subtitle_tag
    # Emit `installNavHotkeys({ allowComma: true })` before :extra_js.
    attr_accessor :nav_hotkeys
    # The mobile tab bar (design system v4.4): below 768px the shell renders
    # `tab_count` nav items as a floating tab bar plus a "More" bottom sheet
    # holding the rest and the app dock. false keeps the hamburger + drawer.
    # Pick the tabs with `tab: true` on nav_items (default: the first four).
    attr_accessor :tab_bar
    attr_accessor :tab_count
    # Fall back to /ds/<file> (a snapshot from `personal_app:ds:snapshot`)
    # when the design-system CDN fails. Only emitted when the snapshot exists.
    attr_accessor :ds_fallback
    attr_writer :ds_base
    # The design-system release the shell loads (PLAT-26): a Hash
    # { "sha" => "937dae3e5599", "files" => { "design-system.css" => "sha384-…", … } }
    # — the design system's v/<sha>/manifest.json. Each file in it is loaded
    # from <ds_base>/v/<sha>/<file> (immutable, cached a year) with its
    # integrity attribute, so an altered file is refused. Defaults to the
    # release this gem version ships (ds_release.json); false loads the
    # always-latest unversioned URLs. With ENV["DS_BASE"] set (a local design
    # system in development) the default is false.
    attr_writer :ds_release
    # Content-Security-Policy the engine sends (PLAT-25): :enforce,
    # :report_only or false (the app's own config/initializers policy, if
    # any, always wins). Scripts and fetches are limited to the app itself
    # and the design-system host; inline scripts stay allowed (the apps'
    # pages use them throughout). Violations are POSTed to /api/csp-reports
    # and land on base's /errors page like any other error.
    attr_accessor :content_security_policy
    # A Proc receiving the ActionDispatch::ContentSecurityPolicy after the
    # engine's defaults, for an app that needs one more source.
    attr_accessor :content_security_policy_extra
    # One key=value line per request (RequestLog). nil = production only.
    attr_writer :request_log

    # --- default controllers --------------------------------------------
    # Parent of the default MCP / backup / health / client-error controllers.
    # A String, constantized when those controllers load, so it can name an
    # autoloaded class.
    attr_accessor :api_base_controller
    attr_writer :mcp_server_name
    attr_accessor :mcp_tool_registry
    # Options for SqliteBackup's `sqlite_backup_config` (prefix defaults to app_id).
    attr_writer :backup
    # A Proc, instance_exec'd in the health controller, returning the targets
    # (it can call probe_client / probe / unconfigured):
    #     app.health_targets = -> { [ probe_client("base", BaseAppClient.new) ] }
    attr_accessor :health_targets
    # Command-palette search (GET /api/search — PersonalAppClient::Search):
    # a callable taking (query, limit:) and returning this app's results as
    # Hashes (kind, title, meta, url, preview). nil = this app has nothing to search.
    #     app.search = ->(q, limit:) { Recipe.search(q).limit(limit).map { |r| {...} } }
    attr_accessor :search
    # The ⌘K command palette (design system shared-core dsPalette): true shows
    # it — the shell renders <meta name="ds-palette" content="<search url>">
    # (empty when config.search is nil: pages and actions only), a search
    # control in the sidebar and the phone "More" sheet. false = no palette.
    attr_accessor :palette
    # Load the design system's apps/<app_id>.css after design-system.css (the
    # styles only this app uses, round three PLAT-27). false = shared file only.
    attr_accessor :app_stylesheet

    # --- railtie ---------------------------------------------------------
    # Options for RateLimit.install! (limit:, period:, path_prefix:, …), or
    # false to leave rate limiting to the app.
    attr_accessor :rate_limit
    # A Proc receiving Rack::Attack, for app-specific throttles.
    attr_accessor :rate_limit_rules

    # --- PWA ---------------------------------------------------------------
    attr_reader :pwa

    # --- error reporting -------------------------------------------------
    attr_reader :error_reporting

    def initialize
      @nav_items = []
      @ds_scripts = []
      @header_style = :inline
      @subtitle_tag = :p
      @nav_hotkeys = true
      @tab_bar = true
      @tab_count = 4
      @ds_fallback = true
      @ds_release = nil
      @content_security_policy = :report_only
      @content_security_policy_extra = nil
      @request_log = nil
      @api_base_controller = "Api::BaseController"
      @mcp_tool_registry = "Mcp::ToolRegistry"
      @backup = {}
      @health_targets = nil
      @search = nil
      @palette = true
      @app_stylesheet = true
      @rate_limit = {}
      @rate_limit_rules = nil
      @pwa = PwaConfig.new
      @error_reporting = ErrorReportingConfig.new
    end

    def app_id
      @app_id.presence || default_app_id
    end

    def app_name
      @app_name.presence || app_id.to_s.capitalize
    end

    def ds_base
      (@ds_base.respond_to?(:call) ? @ds_base.call : @ds_base).presence ||
        ENV["DS_BASE"].presence || DEFAULT_DS_BASE
    end

    def request_log?
      return @request_log unless @request_log.nil?
      defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.production?
    end

    # "apps/<app_id>.css", or nil when config.app_stylesheet is off.
    def app_stylesheet_file
      app_stylesheet ? "apps/#{app_id}.css" : nil
    end

    # Every file the snapshot copies: DS_FILES plus this app's stylesheet.
    def ds_snapshot_files
      DS_FILES + [ app_stylesheet_file ].compact
    end

    def ds_release
      return nil if @ds_release == false
      return @ds_release if @ds_release.is_a?(Hash)
      return nil if ENV["DS_BASE"].present?
      self.class.shipped_ds_release
    end

    # The release pinned by this gem version (lib/personal_app_client/ds_release.json,
    # a copy of the design system's v/current.json at release time).
    def self.shipped_ds_release
      @shipped_ds_release ||= JSON.parse(File.read(File.expand_path("ds_release.json", __dir__))).freeze
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # scheme://host[:port] of ds_base, for the CSP.
    def ds_origin
      uri = URI.parse(ds_base)
      port = uri.port && ![ 80, 443 ].include?(uri.port) ? ":#{uri.port}" : ""
      "#{uri.scheme}://#{uri.host}#{port}"
    end

    def mcp_server_name
      @mcp_server_name.presence || "#{app_id}-mcp"
    end

    # The keyword arguments handed to `sqlite_backup_config`.
    def backup_options
      { prefix: app_id, extra_files: %w[CLAUDE.md README.md] }.merge(@backup.to_h.transform_keys(&:to_sym))
    end

    def backup
      @backup
    end

    # Sync design-system scripts, in load order.
    def ds_sync_scripts
      (CORE_DS_SCRIPTS + Array(ds_scripts).map(&:to_s) + TAIL_DS_SCRIPTS).uniq
    end

    def ds_deferred_scripts
      DEFERRED_DS_SCRIPTS
    end

    private

    def default_app_id
      app = defined?(::Rails) && ::Rails.respond_to?(:application) ? ::Rails.application : nil
      name = app && app.class.respond_to?(:module_parent_name) ? app.class.module_parent_name : nil
      name.present? ? name.underscore : "app"
    end

    class PwaConfig
      # true: register /service-worker.js; false: neither serve nor register
      # it; :unregister: serve a worker that removes itself, and unregister
      # from the page (the kill switch). nil means "production only".
      attr_accessor :service_worker
      attr_accessor :description, :short_name
      # { light: "#…", dark: "#…" } — the <meta name="theme-color"> values.
      attr_accessor :theme_colors
      # Origins whose GETs the service worker serves stale-while-revalidate
      # (the design system and the font/library CDNs). The DS origin is
      # always included.
      attr_accessor :cache_origins

      def initialize
        @service_worker = nil
        @theme_colors = DEFAULT_THEME_COLORS.dup
        @cache_origins = %w[https://fonts.googleapis.com https://fonts.gstatic.com
                            https://cdn.jsdelivr.net https://unpkg.com]
      end

      def service_worker_mode
        return @service_worker unless @service_worker.nil?
        defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.production?
      end
    end

    class ErrorReportingConfig
      DEFAULT_IGNORE = %w[
        ActionController::RoutingError ActionController::UnknownFormat
        ActionController::InvalidAuthenticityToken ActionController::BadRequest
        ActionController::ParameterMissing ActionDispatch::Http::MimeNegotiation::InvalidType
        ActiveRecord::RecordNotFound
      ].freeze

      # nil means "production only".
      attr_accessor :enabled
      # Deliver on a background thread (true) or inline (false — tests).
      attr_accessor :async
      # Seconds during which a repeat of the same fingerprint is counted, not sent.
      attr_accessor :window
      # A callable taking the payload Hash. Default: HubClient#report_error.
      # base (the hub itself) sets one that writes its own table.
      attr_accessor :via
      # Error class names never reported.
      attr_accessor :ignore
      # Accept browser reports at POST /api/client-errors.
      attr_accessor :client_errors

      def initialize
        @enabled = nil
        @async = true
        @window = 300
        @via = nil
        @ignore = DEFAULT_IGNORE.dup
        @client_errors = true
      end

      def enabled?
        return @enabled unless @enabled.nil?
        defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.production? ? true : false
      end
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    # For tests: forget every setting.
    def reset_config!
      @config = Configuration.new
    end
  end
end
