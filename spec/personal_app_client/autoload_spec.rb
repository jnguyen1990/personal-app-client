require "open3"

# v0.8.0: apps reference concerns without a require line. Checked in a fresh
# process, since this suite has already required most files by path.
RSpec.describe "autoloading" do
  it "resolves every optional module from a bare require of the gem" do
    script = <<~RUBY
      require "personal_app_client"
      mods = %w[CloudflareAccess ErrorReporting JwksCache Nav RateLimit Routes DsSnapshot TestSupport
                Mcp::BaseTool Mcp::Registry
                Rails::ApiErrors Rails::ApiKeyAuth Rails::DateParams Rails::HealthCheck Rails::InterAppAuth
                Rails::InterAppAuthOptional Rails::JobStatusReporting Rails::McpDispatch
                Rails::OauthResourceServer Rails::OperatorAuth Rails::SettingStore Rails::SqliteBackup Rails::WellKnown]
      mods.each { |m| PersonalAppClient.const_get(m) }
      # The old explicit requires still work alongside the autoloads.
      require "personal_app_client/rails/sqlite_backup"
      abort "engine loaded without Rails" if defined?(PersonalAppClient::Engine)
      puts "ok"
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)
    expect(status).to be_success, err
    expect(out.strip).to eq("ok")
  end
end
