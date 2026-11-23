require_relative "personal_app_client/version"
require_relative "personal_app_client/errors"
require_relative "personal_app_client/time_zone"
require_relative "personal_app_client/revision"
require_relative "personal_app_client/dates"
require_relative "personal_app_client/client"
require_relative "personal_app_client/app_client"
require_relative "personal_app_client/hub_client"
require_relative "personal_app_client/configuration"

module PersonalAppClient
  # Everything else loads on first reference (v0.8.0+), so apps no longer
  # need a `require "personal_app_client/…"` line per concern. The explicit
  # requires keep working.
  autoload :CloudflareAccess, "personal_app_client/cloudflare_access"
  autoload :JwksCache, "personal_app_client/jwks_cache"
  autoload :Nav, "personal_app_client/nav"
  autoload :RateLimit, "personal_app_client/rate_limit"
  autoload :Routes, "personal_app_client/routes"
  autoload :DsSnapshot, "personal_app_client/ds_snapshot"
  autoload :TestSupport, "personal_app_client/test_support"

  module Mcp
    autoload :BaseTool, "personal_app_client/mcp/base_tool"
    autoload :Registry, "personal_app_client/mcp/registry"
  end

  module Rails
    autoload :ApiErrors, "personal_app_client/rails/api_errors"
    autoload :ApiKeyAuth, "personal_app_client/rails/api_key_auth"
    autoload :DateParams, "personal_app_client/rails/date_params"
    autoload :HealthCheck, "personal_app_client/rails/health_check"
    autoload :InterAppAuth, "personal_app_client/rails/inter_app_auth"
    autoload :InterAppAuthOptional, "personal_app_client/rails/inter_app_auth_optional"
    autoload :JobStatusReporting, "personal_app_client/rails/job_status_reporting"
    autoload :McpDispatch, "personal_app_client/rails/mcp_dispatch"
    autoload :OauthResourceServer, "personal_app_client/rails/oauth_resource_server"
    autoload :OperatorAuth, "personal_app_client/rails/operator_auth"
    autoload :SettingStore, "personal_app_client/rails/setting_store"
    autoload :SqliteBackup, "personal_app_client/rails/sqlite_backup"
    autoload :WellKnown, "personal_app_client/rails/well_known"
  end
end

require_relative "personal_app_client/engine" if defined?(::Rails::Engine)
