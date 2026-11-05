require "active_support"
require "active_support/string_inquirer"

# Minimal Rails stand-in shared by the concern specs. Individual spec files
# reopen this module to add what they touch (root, logger, application).
module Rails
  class << self
    attr_writer :env

    def application
      @application
    end

    def env
      ActiveSupport::StringInquirer.new((@env || "test").to_s)
    end
  end
end

module FakeRailsEnv
  # Run a block with Rails.env temporarily set (e.g. "production").
  def with_rails_env(name)
    previous = Rails.instance_variable_get(:@env)
    Rails.env = name
    yield
  ensure
    Rails.env = previous
  end
end
