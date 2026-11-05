require "ostruct"
require "personal_app_client/test_support"

# Stands in for an ActionDispatch::IntegrationTest: `post` and `response`.
class FakeIntegrationTest
  include PersonalAppClient::TestSupport

  attr_reader :posted, :response

  def initialize(body = "{}")
    @response = OpenStruct.new(body: body)
  end

  def post(path, **options)
    @posted = { path: path, **options }
  end
end

RSpec.describe PersonalAppClient::TestSupport do
  let(:test_case) { FakeIntegrationTest.new }

  around do |example|
    saved = ENV.to_h.slice("INTER_APP_SECRET", "MCP_API_KEY")
    ENV["INTER_APP_SECRET"] = "test-inter-app-secret"
    ENV["MCP_API_KEY"] = "test-mcp-key-from-env"
    example.run
  ensure
    ENV.delete("INTER_APP_SECRET")
    ENV.delete("MCP_API_KEY")
    saved.each { |k, v| ENV[k] = v }
  end

  describe "#inter_app_headers" do
    it "carries the inter-app secret, read at call time" do
      expect(test_case.inter_app_headers).to eq("X-App-Auth" => "test-inter-app-secret")
      ENV["INTER_APP_SECRET"] = "rotated"
      expect(test_case.inter_app_headers).to eq("X-App-Auth" => "rotated")
    end

    it "adds the JSON headers on request" do
      expect(test_case.inter_app_headers(json: true)).to include(
        "X-App-Auth" => "test-inter-app-secret", "Content-Type" => "application/json",
        "HTTP_USER_AGENT" => described_class::MODERN_UA
      )
    end
  end

  describe "#mcp_headers" do
    it "sends the shared key as X-API-Key with JSON headers" do
      expect(test_case.mcp_headers).to include(
        "X-API-Key" => "test-mcp-key-from-env", "Content-Type" => "application/json"
      )
    end

    it "falls back to a fixed key when nothing is configured" do
      ENV.delete("MCP_API_KEY")
      allow(Rails).to receive(:application).and_return(nil)
      expect(test_case.mcp_headers["X-API-Key"]).to eq("test-mcp-key")
    end

    it "falls back to Rails credentials before the fixed key" do
      ENV.delete("MCP_API_KEY")
      app = OpenStruct.new(credentials: { mcp: { api_key: "from-credentials" } })
      allow(Rails).to receive(:application).and_return(app)
      expect(test_case.mcp_headers["X-API-Key"]).to eq("from-credentials")
    end
  end

  describe "#mcp_call" do
    it "POSTs a JSON-RPC envelope to /api/mcp and parses the response" do
      test_case = FakeIntegrationTest.new('{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}')
      body = test_case.mcp_call("tools/call", name: "list_items", arguments: { limit: 2 })

      expect(body).to eq("jsonrpc" => "2.0", "id" => 1, "result" => { "tools" => [] })
      expect(test_case.posted[:path]).to eq("/api/mcp")
      expect(test_case.posted[:headers]).to eq(test_case.mcp_headers)
      expect(JSON.parse(test_case.posted[:params])).to eq(
        "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params" => { "name" => "list_items", "arguments" => { "limit" => 2 } }
      )
    end

    it "defaults params to an empty object" do
      test_case.mcp_call("tools/list")
      expect(JSON.parse(test_case.posted[:params])["params"]).to eq({})
    end
  end

  it "#mcp_tool_result digs the JSON text out of a tools/call response" do
    body = { "result" => { "content" => [ { "type" => "text", "text" => '{"items":[1]}' } ] } }
    expect(test_case.mcp_tool_result(body)).to eq("items" => [ 1 ])
  end

  describe ".block_network!" do
    it "is a no-op returning false when WebMock is not loaded" do
      hide_const("WebMock")
      expect(described_class.block_network!).to be(false)
    end

    it "turns on WebMock's net block, leaving localhost open" do
      webmock = Module.new do
        def self.disable_net_connect!(**options) = (@options = options)
        def self.options = @options
      end
      stub_const("WebMock", webmock)

      expect(described_class.block_network!).to be(true)
      expect(webmock.options).to eq(allow_localhost: true)

      described_class.block_network!(allow_localhost: false, allow: "example.test")
      expect(webmock.options).to eq(allow_localhost: false, allow: "example.test")
    end
  end
end
