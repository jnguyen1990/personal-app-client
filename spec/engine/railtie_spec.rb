RSpec.describe PersonalAppClient::Engine do
  it "defaults the app's time zone to PersonalAppClient::TIME_ZONE" do
    expect(Rails.application.config.time_zone).to eq("America/Winnipeg")
    expect(Time.zone.name).to eq("America/Winnipeg")
  end

  it "installs rate limiting from config.rate_limit" do
    expect(Rails.application.middleware.middlewares).to include(Rack::Attack)
    expect(PersonalAppClient::RateLimit.installed?).to be(true)
    expect(Rack::Attack.throttles["api/ip"].limit).to eq(1000)
  end

  it "throttles /api/ with the JSON 429" do
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.throttles["api/ip"].instance_variable_set(:@limit, 2)
    3.times { get "/api/health/inter-app", {}, { "REMOTE_ADDR" => "10.9.9.9" } }
    expect(last_response.status).to eq(429)
    expect(json).to eq("error" => "rate limit exceeded")
  ensure
    Rack::Attack.throttles["api/ip"].instance_variable_set(:@limit, 1000)
  end

  it "makes the concerns resolvable without a require" do
    %w[ApiErrors ApiKeyAuth DateParams HealthCheck InterAppAuth InterAppAuthOptional JobStatusReporting
       McpDispatch OauthResourceServer OperatorAuth SettingStore SqliteBackup WellKnown].each do |name|
      expect(PersonalAppClient::Rails.const_get(name)).to be_a(Module)
    end
    expect(PersonalAppClient::Mcp::BaseTool).to be_a(Class)
    expect(PersonalAppClient::TestSupport).to be_a(Module)
  end

  it "eager-loads cleanly (production boot)" do
    expect { Rails.autoloaders.each(&:eager_load) }.not_to raise_error
    expect(PersonalAppClient::BackupsController.sqlite_backup_options).to include(prefix: "dummy", extra_files: %w[README.md])
  end
end
