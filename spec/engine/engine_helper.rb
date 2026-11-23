# Boots spec/dummy — a real Rails app on the engine — in its own process:
# the unit specs under spec/ run against a fake ::Rails and cannot share one.
# Run with `bundle exec rake spec:engine` (or `rake`, which runs both).
ENV["RAILS_ENV"] = "test"
ENV["INTER_APP_SECRET"] = "engine-spec-secret"
ENV["MCP_API_KEY"] = "engine-spec-mcp-key"
ENV.delete("DS_BASE")

DUMMY_ROOT = File.expand_path("../dummy", __dir__)
ENV["DUMMY_DB"] = File.join(DUMMY_ROOT, "tmp", "engine-spec-#{Process.pid}.sqlite3")

require File.join(DUMMY_ROOT, "config", "environment")
require "rack/test"
require "json"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :notes, force: true do |t|
    t.string :body
  end
end

module EngineSpecHelpers
  include Rack::Test::Methods
  include PersonalAppClient::TestSupport

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  def html
    last_response.body
  end

  def get_html(path, headers = {})
    get path, {}, { "HTTP_USER_AGENT" => PersonalAppClient::TestSupport::MODERN_UA }.merge(headers)
  end

  def secret_headers
    { "HTTP_X_APP_AUTH" => ENV["INTER_APP_SECRET"] }
  end

  def mcp_rack_headers
    { "CONTENT_TYPE" => "application/json", "HTTP_X_API_KEY" => ENV["MCP_API_KEY"] }
  end

  def mcp_post(method, params = {})
    post "/api/mcp", { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json, mcp_rack_headers
    JSON.parse(last_response.body)
  end
end

RSpec.configure do |config|
  config.include EngineSpecHelpers
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before do
    Dummy::DELIVERED_ERRORS.clear
  end

  config.after(:suite) do
    ActiveRecord::Base.connection_pool.disconnect!
    Dir["#{ENV['DUMMY_DB']}*"].each { |f| File.delete(f) } # the db and its -wal / -shm
    Dir[File.join(DUMMY_ROOT, "tmp", "dummy_backup_*.zip")].each { |f| File.delete(f) }
  end
end
