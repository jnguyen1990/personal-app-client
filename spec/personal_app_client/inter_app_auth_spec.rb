require "ostruct"
require "personal_app_client/rails/inter_app_auth"

# Minimal stand-in for an ActionController::Base instance — enough surface
# to exercise the concern without booting Rails.
class FakeController
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

  include PersonalAppClient::Rails::InterAppAuth
end

RSpec.describe PersonalAppClient::Rails::InterAppAuth do
  let(:controller) { FakeController.new }
  before { ENV["INTER_APP_SECRET"] = "secret-xyz" }
  after  { ENV.delete("INTER_APP_SECRET") }

  it "registers a before_action" do
    expect(FakeController.before_actions).to include(:authenticate_inter_app!)
  end

  it "passes when X-App-Auth matches" do
    controller.request = OpenStruct.new(headers: { "X-App-Auth" => "secret-xyz" })
    controller.send(:authenticate_inter_app!)
    expect(controller.rendered).to be_nil
  end

  it "rejects when X-App-Auth missing" do
    controller.request = OpenStruct.new(headers: {})
    controller.send(:authenticate_inter_app!)
    expect(controller.rendered).to eq(json: { error: "unauthorized" }, status: :unauthorized)
  end

  it "rejects when X-App-Auth wrong" do
    controller.request = OpenStruct.new(headers: { "X-App-Auth" => "nope" })
    controller.send(:authenticate_inter_app!)
    expect(controller.rendered[:status]).to eq(:unauthorized)
  end

  it "503s when INTER_APP_SECRET unset" do
    ENV.delete("INTER_APP_SECRET")
    controller.request = OpenStruct.new(headers: { "X-App-Auth" => "secret-xyz" })
    controller.send(:authenticate_inter_app!)
    expect(controller.rendered[:status]).to eq(:service_unavailable)
  end
end
