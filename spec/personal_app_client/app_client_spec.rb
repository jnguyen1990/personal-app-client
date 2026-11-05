require "logger"
require "stringio"

RSpec.describe PersonalAppClient::AppClient do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }
  let(:settings) { {} }

  # A wrapper the way an app writes one.
  let(:client_class) do
    store = settings
    Class.new(described_class) do
      app_client name: "fitness", setting: "fitness_app_url", dev_url: "http://localhost:3000"

      define_method(:setting_value) { |key| store[key] }

      def self.name = "FitnessAppClient"

      def blocks
        attempt("blocks", default: []) { |http| http.get("/api/blocks") }
      end

      def goals!
        http!.get("/api/goals")
      end

      def legacy_blocks # the pre-0.7 hand-rolled shape still works
        return [] unless configured?
        @http.get("/api/blocks")
      rescue PersonalAppClient::Error
        []
      end
    end
  end

  def build(env: "production", **options)
    client_class.new(env: env, logger: logger, **options)
  end

  describe "URL resolution" do
    it "uses the Setting value" do
      settings["fitness_app_url"] = "http://fitness.tail5ece07.ts.net:3002"
      client = build
      expect(client).to be_configured
      expect(client.base_url).to eq("http://fitness.tail5ece07.ts.net:3002")
    end

    it "is unconfigured in production when the URL is missing — never localhost" do
      client = build(env: "production")
      expect(client).not_to be_configured
      expect(client.base_url).to be_nil
      expect(log_io.string).to be_empty
    end

    it "treats a blank Setting like a missing one" do
      settings["fitness_app_url"] = "  "
      expect(build(env: "production")).not_to be_configured
    end

    it "falls back to dev_url in development and test" do
      expect(build(env: "development").base_url).to eq("http://localhost:3000")
      expect(build(env: "test").base_url).to eq("http://localhost:3000")
    end

    it "prefers the Setting over dev_url outside production too" do
      settings["fitness_app_url"] = "http://127.0.0.1:4000"
      expect(build(env: "development").base_url).to eq("http://127.0.0.1:4000")
    end

    it "force_dev_url pins development to dev_url, ignoring the Setting" do
      settings["fitness_app_url"] = "http://fitness.tail5ece07.ts.net:3002"
      klass = Class.new(client_class) { app_client force_dev_url: true }
      expect(klass.new(env: "development", logger: logger).base_url).to eq("http://localhost:3000")
      expect(klass.new(env: "production", logger: logger).base_url).to eq("http://fitness.tail5ece07.ts.net:3002")
    end

    it "fallback_envs narrows where dev_url applies" do
      klass = Class.new(client_class) { app_client fallback_envs: %w[development] }
      expect(klass.new(env: "test", logger: logger)).not_to be_configured
      expect(klass.new(env: "development", logger: logger)).to be_configured
    end

    it "takes the first present of several setting keys" do
      klass = Class.new(client_class) { app_client setting: %w[base_app_url self_app_url] }
      settings["self_app_url"] = "http://base.tail5ece07.ts.net:3001"
      expect(klass.new(env: "production", logger: logger).base_url).to eq("http://base.tail5ece07.ts.net:3001")
    end

    it "accepts an explicit base_url" do
      expect(build(base_url: "http://10.0.0.5:3002").base_url).to eq("http://10.0.0.5:3002")
    end

    it "logs and goes unconfigured when the Client rejects the URL" do
      settings["fitness_app_url"] = "https://fitness.joenguyen.ca"
      client = build(env: "production")
      expect(client).not_to be_configured
      expect(log_io.string).to include("FitnessAppClient: Refusing to use public/proxied URL")
    end

    it "reads Setting.get when the app has a Setting model" do
      stub_const("Setting", Class.new { def self.get(key) = key == "upkeep_app_url" ? "http://10.0.0.9:3005" : nil })
      klass = Class.new(described_class) { app_client setting: "upkeep_app_url" }
      expect(klass.new(env: "production").base_url).to eq("http://10.0.0.9:3005")
    end

    it "inherits options without leaking a subclass's changes upward" do
      Class.new(client_class) { app_client name: "other" }
      expect(client_class.app_client_options[:name]).to eq("fitness")
    end
  end

  describe "secrets and timeouts" do
    it "reads INTER_APP_SECRET lazily, at construction" do
      saved = ENV["INTER_APP_SECRET"]
      ENV["INTER_APP_SECRET"] = "from-env"
      expect(PersonalAppClient::Client).to receive(:new)
        .with(hash_including(secret: "from-env", base_url: "http://localhost:3000", env: "test"))
      build(env: "test")
    ensure
      ENV["INTER_APP_SECRET"] = saved
    end

    it "passes configured timeouts through" do
      klass = Class.new(client_class) { app_client open_timeout: 3, read_timeout: 5 }
      expect(PersonalAppClient::Client).to receive(:new).with(hash_including(open_timeout: 3, read_timeout: 5))
      klass.new(env: "test", logger: logger)
    end
  end

  context "against a server" do
    let(:server) { StubServer.new }
    after { server.stop }
    let(:client) { build(base_url: server.url, env: "test") }

    it "#attempt returns the block's value" do
      server.on(:get, "/api/blocks") { |_req, res| res.body = JSON.dump([ { "id" => 1 } ]) }
      expect(client.blocks).to eq([ { "id" => 1 } ])
      expect(client.legacy_blocks).to eq([ { "id" => 1 } ])
    end

    it "#attempt logs and returns the default on a PersonalAppClient error" do
      server.on(:get, "/api/blocks") { |_req, res| res.status = 500 }
      expect(client.blocks).to eq([])
      expect(log_io.string).to match(/ERROR.*FitnessAppClient: blocks: HTTP 500/)
    end

    it "#attempt does not swallow other errors" do
      server.on(:get, "/api/blocks") { |_req, res| res.body = "[]" }
      allow(JSON).to receive(:parse).and_raise(NoMemoryError)
      expect { client.blocks }.to raise_error(NoMemoryError)
    end

    it "#http! raises through for the bang variants" do
      server.on(:get, "/api/goals") { |_req, res| res.status = 404 }
      expect { client.goals! }.to raise_error(PersonalAppClient::ResponseError)
    end

    describe "#ping" do
      it "reports success with the status and URL" do
        server.on(:get, "/up") { |_req, res| res.body = "<html>ok</html>" }
        expect(client.ping).to eq(success: true, status: 200, url: server.url)
      end

      it "reports an HTTP failure without raising" do
        server.on(:get, "/up") { |_req, res| res.status = 502 }
        result = client.ping
        expect(result).to include(success: false, status: 502, url: server.url)
        expect(result[:error]).to match(/HTTP 502/)
      end

      it "pings a custom path" do
        server.on(:get, "/api/health/inter-app") { |_req, res| res.body = "{}" }
        expect(client.ping("/api/health/inter-app")[:success]).to be(true)
      end
    end
  end

  describe "when unconfigured" do
    let(:client) { build(env: "production") }

    it "#attempt returns the default without calling the block" do
      expect(client.blocks).to eq([])
    end

    it "#http! raises ConfigurationError naming the app" do
      expect { client.goals! }
        .to raise_error(PersonalAppClient::ConfigurationError, "fitness app not configured")
    end

    it "#ping says so" do
      expect(client.ping).to eq(success: false, error: "fitness URL not configured")
    end
  end

  it "#ping reports a connection failure without raising" do
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    result = build(base_url: "http://127.0.0.1:#{port}", env: "test").ping
    expect(result).to include(success: false, url: "http://127.0.0.1:#{port}")
    expect(result[:error]).to match(/ECONNREFUSED/)
    expect(result).not_to have_key(:status)
  end
end
