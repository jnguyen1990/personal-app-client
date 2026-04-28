require "ostruct"
require "personal_app_client/rails/api_key_auth"

# Minimal Rails stand-in so the concern's `::Rails.application.credentials.dig`
# call doesn't blow up in unit tests.
module Rails
  def self.application
    @application ||= OpenStruct.new(credentials: {})
  end
end

class FakeApiKeyController
  attr_reader :rendered

  def self.before_actions
    @before_actions ||= []
  end

  def self.before_action(method_name)
    before_actions << method_name
  end

  attr_writer :request

  def request
    @request ||= OpenStruct.new(headers: {})
  end

  def render(payload)
    @rendered = payload
  end

  include PersonalAppClient::Rails::ApiKeyAuth
end

class FakeBridgeController
  attr_reader :rendered

  def self.before_actions
    @before_actions ||= []
  end

  def self.before_action(method_name)
    before_actions << method_name
  end

  attr_writer :request

  def request
    @request ||= OpenStruct.new(headers: {})
  end

  def render(payload)
    @rendered = payload
  end

  include PersonalAppClient::Rails::ApiKeyAuth
  api_key_config env: "BRIDGE_API_KEY", credential: [ :bridge, :api_key ]
end

RSpec.describe PersonalAppClient::Rails::ApiKeyAuth do
  describe "defaults (MCP_API_KEY)" do
    let(:controller) { FakeApiKeyController.new }
    before { ENV["MCP_API_KEY"] = "mcp-secret" }
    after  { ENV.delete("MCP_API_KEY") }

    it "registers a before_action" do
      expect(FakeApiKeyController.before_actions).to include(:authenticate_api_key!)
    end

    it "passes with X-API-Key matching ENV" do
      controller.request = OpenStruct.new(headers: { "X-API-Key" => "mcp-secret" })
      controller.send(:authenticate_api_key!)
      expect(controller.rendered).to be_nil
    end

    it "passes with Authorization Bearer matching ENV" do
      controller.request = OpenStruct.new(headers: { "Authorization" => "Bearer mcp-secret" })
      controller.send(:authenticate_api_key!)
      expect(controller.rendered).to be_nil
    end

    it "rejects when neither header is present" do
      controller.request = OpenStruct.new(headers: {})
      controller.send(:authenticate_api_key!)
      expect(controller.rendered[:status]).to eq(:unauthorized)
    end

    it "rejects when wrong key" do
      controller.request = OpenStruct.new(headers: { "X-API-Key" => "nope" })
      controller.send(:authenticate_api_key!)
      expect(controller.rendered[:status]).to eq(:unauthorized)
    end

    it "503s when MCP_API_KEY unset" do
      ENV.delete("MCP_API_KEY")
      controller.request = OpenStruct.new(headers: { "X-API-Key" => "mcp-secret" })
      controller.send(:authenticate_api_key!)
      expect(controller.rendered[:status]).to eq(:service_unavailable)
    end
  end

  describe "configured (BRIDGE_API_KEY)" do
    let(:controller) { FakeBridgeController.new }
    before { ENV["BRIDGE_API_KEY"] = "bridge-secret" }
    after  { ENV.delete("BRIDGE_API_KEY") }

    it "uses the configured env var" do
      controller.request = OpenStruct.new(headers: { "X-API-Key" => "bridge-secret" })
      controller.send(:authenticate_api_key!)
      expect(controller.rendered).to be_nil
    end

    it "503s when BRIDGE_API_KEY unset" do
      ENV.delete("BRIDGE_API_KEY")
      controller.send(:authenticate_api_key!)
      expect(controller.rendered[:status]).to eq(:service_unavailable)
      expect(controller.rendered[:json][:error]).to include("BRIDGE_API_KEY")
    end
  end
end
