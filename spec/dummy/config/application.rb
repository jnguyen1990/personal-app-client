# A minimal Rails app the engine specs (spec/engine) boot. Shaped like the
# real apps: Api::BaseController, an Mcp::ToolRegistry, a BaseAppClient, and
# a one-line layout that renders the engine's shell.
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

require "personal_app_client"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = ENV["EAGER_LOAD"] == "1"
    config.secret_key_base = "dummy" * 16
    config.logger = Logger.new(File::NULL)
    config.active_support.deprecation = :stderr
    config.action_dispatch.show_exceptions = :all
    config.hosts.clear
    config.active_job.queue_adapter = :inline
  end
end
