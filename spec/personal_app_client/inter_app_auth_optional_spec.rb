require "ostruct"
require "personal_app_client/rails/inter_app_auth_optional"

class FakeOptionalController
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

  include PersonalAppClient::Rails::InterAppAuthOptional
end

RSpec.describe PersonalAppClient::Rails::InterAppAuthOptional do
  let(:controller) { FakeOptionalController.new }
  before { ENV["INTER_APP_SECRET"] = "secret-xyz" }
  after  { ENV.delete("INTER_APP_SECRET") }

  it "registers a before_action" do
    expect(FakeOptionalController.before_actions).to include(:verify_inter_app_secret_if_present!)
  end

  it "passes when header is absent (browser path)" do
    controller.request = OpenStruct.new(headers: {})
    controller.send(:verify_inter_app_secret_if_present!)
    expect(controller.rendered).to be_nil
  end

  it "passes when X-App-Auth matches" do
    controller.request = OpenStruct.new(headers: { "X-App-Auth" => "secret-xyz" })
    controller.send(:verify_inter_app_secret_if_present!)
    expect(controller.rendered).to be_nil
  end

  it "rejects when X-App-Auth wrong" do
    controller.request = OpenStruct.new(headers: { "X-App-Auth" => "nope" })
    controller.send(:verify_inter_app_secret_if_present!)
    expect(controller.rendered[:status]).to eq(:unauthorized)
  end

  it "503s when header present but INTER_APP_SECRET unset" do
    ENV.delete("INTER_APP_SECRET")
    controller.request = OpenStruct.new(headers: { "X-App-Auth" => "anything" })
    controller.send(:verify_inter_app_secret_if_present!)
    expect(controller.rendered[:status]).to eq(:service_unavailable)
  end

  it "passes through unconfigured server when no header (browser path stays open)" do
    ENV.delete("INTER_APP_SECRET")
    controller.request = OpenStruct.new(headers: {})
    controller.send(:verify_inter_app_secret_if_present!)
    expect(controller.rendered).to be_nil
  end
end
