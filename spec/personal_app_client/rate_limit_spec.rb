require "rack"
require "rack/mock"
require "active_support/cache"
require "personal_app_client/rate_limit"

RSpec.describe PersonalAppClient::RateLimit do
  # Records `config.middleware.use` the way a Rails application would.
  let(:fake_app) do
    middleware = Class.new do
      attr_reader :used
      def initialize = @used = []
      def use(klass, *) = @used << klass
    end.new
    Struct.new(:config).new(Struct.new(:middleware).new(middleware))
  end

  let(:inner) { ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] } }

  def stack
    Rack::Attack.new(inner)
  end

  def get(path, ip: "10.0.0.1")
    Rack::MockRequest.new(stack).get(path, "REMOTE_ADDR" => ip)
  end

  before do
    described_class.instance_variable_set(:@installed, nil)
    require "rack/attack"
    Rack::Attack.clear_configuration
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  after do
    Rack::Attack.clear_configuration
    described_class.instance_variable_set(:@installed, nil)
  end

  describe "the default throttle" do
    before { described_class.install!(app: fake_app, limit: 3) }

    it "lets requests through up to the limit, then answers 429 JSON" do
      3.times { expect(get("/api/things").status).to eq(200) }

      response = get("/api/things")
      expect(response.status).to eq(429)
      expect(response.headers["content-type"]).to eq("application/json")
      expect(response.headers["retry-after"]).to eq("60")
      expect(JSON.parse(response.body)).to eq("error" => "rate limit exceeded")
    end

    it "counts per IP" do
      4.times { get("/api/things", ip: "10.0.0.1") }
      expect(get("/api/things", ip: "10.0.0.2").status).to eq(200)
    end

    it "only covers /api/" do
      10.times { expect(get("/settings").status).to eq(200) }
    end
  end

  it "defaults to 120 requests a minute" do
    described_class.install!(app: fake_app)
    throttle = Rack::Attack.throttles.fetch("api/ip")
    expect([ throttle.limit, throttle.period ]).to eq([ 120, 60 ])
  end

  it "takes a block for app-specific rules, keeping the default" do
    described_class.install!(app: fake_app) do |attack|
      attack.throttle("icloud-bridge/ip", limit: 1, period: 30) do |req|
        req.ip if req.path.start_with?("/api/icloud-bridge/")
      end
    end

    expect(Rack::Attack.throttles.keys).to contain_exactly("api/ip", "icloud-bridge/ip")
    expect(get("/api/icloud-bridge/poll").status).to eq(200)
    limited = get("/api/icloud-bridge/poll")
    expect(limited.status).to eq(429)
    expect(limited.headers["retry-after"]).to eq("30") # the tripped rule's period
  end

  it "can drop the default throttle" do
    described_class.install!(app: fake_app, api_throttle: false)
    expect(Rack::Attack.throttles).to be_empty
  end

  describe "middleware insertion" do
    it "inserts Rack::Attack once, however often install! runs" do
      3.times { described_class.install!(app: fake_app) }
      expect(fake_app.config.middleware.used).to eq([ Rack::Attack ])
      expect(Rack::Attack.throttles.keys).to eq([ "api/ip" ])
    end

    it "leaves insertion to rack-attack's railtie when that was already loaded" do
      stub_const("Rack::Attack::Railtie", Class.new)
      described_class.install!(app: fake_app)
      expect(fake_app.config.middleware.used).to be_empty
      expect(Rack::Attack.throttles.keys).to eq([ "api/ip" ])
    end

    it "defaults to Rails.application" do
      allow(Rails).to receive(:application).and_return(fake_app)
      described_class.install!
      expect(fake_app.config.middleware.used).to eq([ Rack::Attack ])
    end

    it "is safe without a Rails application" do
      allow(Rails).to receive(:application).and_return(nil)
      expect { described_class.install! }.not_to raise_error
    end
  end
end
