require "active_support/time"
require "personal_app_client/rails/health_check"

class FakeHealthController < FakeActionController
  include PersonalAppClient::Rails::HealthCheck
end

class FakeProbingHealthController < FakeActionController
  include PersonalAppClient::Rails::HealthCheck

  private

  def health_targets
    [
      probe("base", "http://base:3001") { :fine },
      probe("fitness", "http://fitness:3002") { raise PersonalAppClient::ResponseError.new("HTTP 500 from fitness", status: 500, body: "", url: "x") },
      probe("weather", "http://weather") { raise IOError, "closed stream" },
      unconfigured("upkeep", nil)
    ]
  end
end

RSpec.describe PersonalAppClient::Rails::HealthCheck do
  around do |example|
    previous = Time.zone
    Time.zone = "UTC"
    example.run
    Time.zone = previous
  end

  before { allow(PersonalAppClient).to receive(:revision).and_return("abc123") }

  it "renders ok with no targets by default, plus the deployed revision" do
    json = FakeHealthController.new.process(:inter_app).rendered[:json]
    expect(json).to include(ok: true, targets: [], revision: "abc123")
    expect(json.keys).to eq(%i[ok checked_at revision targets])
    expect(Time.iso8601(json[:checked_at])).to be_within(5).of(Time.now)
  end

  it "reports a nil revision when it cannot be determined" do
    allow(PersonalAppClient).to receive(:revision).and_return(nil)
    json = FakeHealthController.new.process(:inter_app).rendered[:json]
    expect(json).to have_key(:revision)
    expect(json[:revision]).to be_nil
  end

  it "builds targets from the health_targets hook" do
    json = FakeProbingHealthController.new.process(:inter_app).rendered[:json]
    base, fitness, weather, upkeep = json[:targets]

    expect(base).to include(name: "base", url: "http://base:3001", status: "ok")
    expect(base[:latency_ms]).to be_a(Integer)
    expect(fitness).to eq(name: "fitness", url: "http://fitness:3002", status: "error", error: "HTTP 500 from fitness")
    expect(weather).to eq(name: "weather", url: "http://weather", status: "error", error: "IOError: closed stream")
    expect(upkeep).to eq(name: "upkeep", url: nil, status: "unconfigured")
    expect(json[:ok]).to be(false)
  end

  it "does not count unconfigured targets as failures" do
    controller = FakeHealthController.new
    allow(controller).to receive(:health_targets).and_return([ controller.send(:unconfigured, "x", nil) ])
    expect(controller.process(:inter_app).rendered[:json][:ok]).to be(true)
  end

  it "keeps the hook and helpers private" do
    expect(FakeHealthController.private_instance_methods)
      .to include(:health_targets, :health_payload, :probe, :unconfigured, :probe_client)
    expect(FakeHealthController.public_instance_methods).to include(:inter_app)
  end

  describe "#probe_client" do
    let(:controller) { FakeHealthController.new }

    def client(configured:, ping: nil)
      double("AppClient", configured?: configured, base_url: configured ? "http://base:3001" : nil, ping: ping)
    end

    it "is unconfigured when the client has no URL" do
      expect(controller.send(:probe_client, "base", client(configured: false)))
        .to eq(name: "base", url: nil, status: "unconfigured")
    end

    it "is ok when the ping succeeds" do
      c = client(configured: true, ping: { success: true, status: 200 })
      expect(controller.send(:probe_client, "base", c)).to include(name: "base", url: "http://base:3001", status: "ok")
      expect(c).to have_received(:ping).with("/up")
    end

    it "is an error carrying the ping's message when it fails" do
      c = client(configured: true, ping: { success: false, error: "HTTP 502 from http://base:3001/up" })
      expect(controller.send(:probe_client, "base", c, "/api/goals/stats"))
        .to eq(name: "base", url: "http://base:3001", status: "error", error: "HTTP 502 from http://base:3001/up")
      expect(c).to have_received(:ping).with("/api/goals/stats")
    end
  end
end
