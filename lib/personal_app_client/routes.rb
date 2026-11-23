module PersonalAppClient
  # The platform routes every app used to write out by hand, drawn by one
  # call at the top level of config/routes.rb:
  #
  #     Rails.application.routes.draw do
  #       personal_app_routes
  #       # … the app's own routes
  #     end
  #
  # Draws, with the same paths, verbs and route names the apps had:
  #
  #     GET  /.well-known/oauth-protected-resource   well_known#protected_resource
  #     GET  /up                                     rails/health#show  (rails_health_check)
  #     GET  /api/health/inter-app                   health#inter_app
  #     GET  /api/backup/create                      backups#create_backup
  #     GET  /api/backup/download/:filename          backups#download
  #     GET  /api/backup/list                        backups#list
  #     POST /api/backup/prune                       backups#prune
  #     POST /api/backup/restore                     backups#restore
  #     POST /api/backup/restore-upload              backups#restore_upload
  #     POST /api/mcp                                mcp#handle
  #
  # plus the engine's own: GET /manifest.json, GET /service-worker.js,
  # GET /offline (PWA).
  #
  # Each group goes to the engine's default controller unless the app names
  # its own (a controller path, as `to:` takes it), or `false` to skip it:
  #
  #     personal_app_routes backups: "api/backups",          # budgeter's bespoke restore
  #                         health: "api/health",            # base's cluster view
  #                         well_known: "oauth/metadata"     # base is the AS
  module Routes
    DEFAULTS = {
      well_known: "personal_app_client/well_known",
      health: "personal_app_client/health",
      backups: "personal_app_client/backups",
      mcp: "personal_app_client/mcp",
      pwa: "personal_app_client/pwa",
      up: "rails/health"
    }.freeze

    def personal_app_routes(**overrides)
      unknown = overrides.keys - DEFAULTS.keys
      raise ArgumentError, "personal_app_routes: unknown option(s) #{unknown.join(', ')}" if unknown.any?

      c = DEFAULTS.merge(overrides)

      # RFC 9728: MCP/OAuth protected-resource discovery (Cloudflare Access bypass path).
      get "/.well-known/oauth-protected-resource", to: "#{c[:well_known]}#protected_resource" if c[:well_known]

      get "up" => "#{c[:up]}#show", as: :rails_health_check if c[:up]

      if c[:pwa]
        get "manifest.json", to: "#{c[:pwa]}#manifest", as: :pwa_manifest, format: false
        get "service-worker.js", to: "#{c[:pwa]}#service_worker", as: :pwa_service_worker, format: false
        get "offline", to: "#{c[:pwa]}#offline", as: :pwa_offline
      end

      scope path: "api", as: "api" do
        # MCP (Model Context Protocol) — JSON-RPC over Streamable HTTP.
        post "mcp", to: "#{c[:mcp]}#handle" if c[:mcp]

        # Inter-app health; base's /api/health/cluster reads every app's.
        get "health/inter-app", to: "#{c[:health]}#inter_app" if c[:health]

        if c[:backups]
          # :filename must permit dots or Rails strips ".zip" as the format.
          get  "backup/create", to: "#{c[:backups]}#create_backup"
          get  "backup/download/:filename", to: "#{c[:backups]}#download", constraints: { filename: %r{[^/]+} }
          get  "backup/list", to: "#{c[:backups]}#list"
          # POST, not GET: prune deletes files. create_backup is a GET only
          # because the mini's backup-pull.sh has always called it that way.
          post "backup/prune", to: "#{c[:backups]}#prune"
          post "backup/restore", to: "#{c[:backups]}#restore"
          post "backup/restore-upload", to: "#{c[:backups]}#restore_upload"
        end
      end
    end
  end

  # Non-DSL form, for `PersonalAppClient.routes(self)` inside routes.draw.
  def self.routes(mapper, **overrides)
    mapper.personal_app_routes(**overrides)
  end
end
