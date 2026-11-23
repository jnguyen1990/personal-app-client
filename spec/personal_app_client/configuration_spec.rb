RSpec.describe PersonalAppClient::Configuration do
  subject(:config) { described_class.new }

  after { ENV.delete("DS_BASE") }

  it "derives the app id and name from the Rails application" do
    stub_const("Upkeep::Application", Class.new { def self.module_parent_name = "Upkeep" })
    allow(Rails).to receive(:application).and_return(Upkeep::Application.new)
    expect(config.app_id).to eq("upkeep")
    expect(config.app_name).to eq("Upkeep")
    expect(config.mcp_server_name).to eq("upkeep-mcp")
  end

  it "lets the app set them" do
    config.app_id = "base"
    config.app_name = "Base"
    config.mcp_server_name = "hub-mcp"
    expect([ config.app_id, config.app_name, config.mcp_server_name ]).to eq(%w[base Base hub-mcp])
  end

  it "reads DS_BASE per call, after an explicit ds_base" do
    expect(config.ds_base).to eq("https://design-system.joenguyen.ca")
    ENV["DS_BASE"] = "http://localhost:8804"
    expect(config.ds_base).to eq("http://localhost:8804")
    config.ds_base = -> { "http://ds.test" }
    expect(config.ds_base).to eq("http://ds.test")
  end

  it "orders the design-system scripts: shared-core, extras, modal-keys" do
    config.ds_scripts = %w[session-render goal-render]
    expect(config.ds_sync_scripts).to eq(%w[shared-core session-render goal-render modal-keys])
    expect(config.ds_deferred_scripts).to eq(%w[apps-launcher])
  end

  it "builds the backup options from app_id with the apps' usual extra files" do
    config.app_id = "fitness"
    config.backup = { include_storage: true }
    expect(config.backup_options).to eq(prefix: "fitness", extra_files: %w[CLAUDE.md README.md], include_storage: true)
  end

  it "turns reporting and the service worker on in production only, unless set" do
    expect(config.error_reporting.enabled?).to be(false)
    expect(config.pwa.service_worker_mode).to be(false)
    with_rails_env("production") do
      expect(config.error_reporting.enabled?).to be(true)
      expect(config.pwa.service_worker_mode).to be(true)
    end
    config.error_reporting.enabled = true
    config.pwa.service_worker = :unregister
    expect(config.error_reporting.enabled?).to be(true)
    expect(config.pwa.service_worker_mode).to eq(:unregister)
  end

  it "is reached through PersonalAppClient.configure" do
    PersonalAppClient.configure { |c| c.app_id = "budgeter" }
    expect(PersonalAppClient.config.app_id).to eq("budgeter")
  ensure
    PersonalAppClient.reset_config!
  end
end
