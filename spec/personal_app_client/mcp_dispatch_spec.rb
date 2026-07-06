require "ostruct"
require "logger"
require "personal_app_client/rails/mcp_dispatch"

# Minimal Rails stand-in (matches api_key_auth_spec style). The dispatch
# concern only touches ::Rails.logger (on the internal-error path).
module Rails
  def self.logger
    @logger ||= Logger.new(File::NULL)
  end
end

class FakeMcpTool
  class << self
    def tool_name = "greet"
    def description = "Greets"
    def input_schema = { type: "object", properties: {} }

    def descriptor
      { name: tool_name, description: description, inputSchema: input_schema }
    end

    def call(args)
      return "plain #{args['name']}" if args["plain"]
      raise "boom" if args["explode"]
      { greeting: "hello #{args['name']}" }
    end
  end
end

module FakeMcpRegistry
  TOOLS = [ FakeMcpTool ].freeze

  def self.descriptors
    TOOLS.map(&:descriptor)
  end

  def self.find(name)
    TOOLS.find { |t| t.tool_name == name }
  end
end

class FakeMcpController
  attr_writer :request
  attr_reader :rendered, :headed

  def request
    @request ||= OpenStruct.new(request_parameters: {})
  end

  def render(payload)
    @rendered = payload
  end

  def head(status)
    @headed = status
  end

  include PersonalAppClient::Rails::McpDispatch
  mcp_config server_name: "test-mcp", tool_registry: FakeMcpRegistry
end

class FakeEmptyMcpController < FakeMcpController
  mcp_config server_name: "empty-mcp",
             no_tools_message: "No tools registered yet on empty"
end

RSpec.describe PersonalAppClient::Rails::McpDispatch do
  let(:controller) { FakeMcpController.new }

  def rpc(method, id: 1, params: nil)
    body = { "method" => method, "id" => id }
    body["params"] = params if params
    controller.request = OpenStruct.new(request_parameters: body)
    controller.handle
    controller.rendered && controller.rendered[:json]
  end

  describe "initialize" do
    it "returns protocol version, capabilities and serverInfo" do
      json = rpc("initialize")
      expect(json[:result]).to eq(
        protocolVersion: "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "test-mcp", version: "0.1.0" }
      )
      expect(json[:jsonrpc]).to eq("2.0")
      expect(json[:id]).to eq(1)
    end
  end

  describe "tools/list" do
    it "returns the registry descriptors" do
      json = rpc("tools/list")
      expect(json[:result]).to eq(tools: [ FakeMcpTool.descriptor ])
    end
  end

  describe "tools/call" do
    it "wraps non-string payloads as pretty JSON text content" do
      json = rpc("tools/call", params: { "name" => "greet", "arguments" => { "name" => "joe" } })
      content = json[:result][:content]
      expect(content).to eq([ { type: "text", text: JSON.pretty_generate(greeting: "hello joe") } ])
    end

    it "passes string payloads through untouched" do
      json = rpc("tools/call", params: { "name" => "greet", "arguments" => { "plain" => true, "name" => "joe" } })
      expect(json[:result][:content]).to eq([ { type: "text", text: "plain joe" } ])
    end

    it "defaults arguments to {} when omitted" do
      json = rpc("tools/call", params: { "name" => "greet" })
      expect(json[:result][:content].first[:type]).to eq("text")
    end

    it "returns -32602 for an unknown tool" do
      json = rpc("tools/call", params: { "name" => "nope" })
      expect(json[:error]).to eq(code: -32602, message: "Unknown tool: nope")
    end

    it "returns -32603 with the message when the tool raises" do
      json = rpc("tools/call", params: { "name" => "greet", "arguments" => { "explode" => true } })
      expect(json[:error]).to eq(code: -32603, message: "Internal error: boom")
    end
  end

  describe "ping" do
    it "returns an empty result" do
      expect(rpc("ping")[:result]).to eq({})
    end
  end

  describe "unknown methods" do
    it "returns -32601" do
      json = rpc("bogus")
      expect(json[:error]).to eq(code: -32601, message: "Method not found: bogus")
    end
  end

  describe "notifications" do
    it "acks id-less notifications with 202 and no body" do
      controller.request = OpenStruct.new(
        request_parameters: { "method" => "notifications/initialized" }
      )
      controller.handle
      expect(controller.headed).to eq(:accepted)
      expect(controller.rendered).to be_nil
    end

    it "dispatches notifications that carry an id" do
      json = rpc("notifications/whatever", id: 7)
      expect(json[:error][:code]).to eq(-32601)
      expect(json[:id]).to eq(7)
    end
  end

  describe "registry resolution" do
    it "accepts a String and constantizes lazily" do
      klass = Class.new(FakeMcpController)
      klass.mcp_config server_name: "s", tool_registry: "FakeMcpRegistry"
      c = klass.new
      c.request = OpenStruct.new(request_parameters: { "method" => "tools/list", "id" => 1 })
      c.handle
      expect(c.rendered[:json][:result]).to eq(tools: [ FakeMcpTool.descriptor ])
    end

    it "accepts a Proc" do
      klass = Class.new(FakeMcpController)
      klass.mcp_config server_name: "s", tool_registry: -> { FakeMcpRegistry }
      c = klass.new
      c.request = OpenStruct.new(request_parameters: { "method" => "tools/list", "id" => 1 })
      c.handle
      expect(c.rendered[:json][:result]).to eq(tools: [ FakeMcpTool.descriptor ])
    end
  end

  describe "with no tool registry (budgeter mode)" do
    let(:controller) { FakeEmptyMcpController.new }

    it "serves initialize with its own server name" do
      expect(rpc("initialize")[:result][:serverInfo]).to eq(name: "empty-mcp", version: "0.1.0")
    end

    it "returns an empty tools list" do
      expect(rpc("tools/list")[:result]).to eq(tools: [])
    end

    it "returns -32601 with the configured message on tools/call" do
      json = rpc("tools/call", params: { "name" => "anything" })
      expect(json[:error]).to eq(code: -32601, message: "No tools registered yet on empty")
    end
  end

  describe "JsonRpcError data" do
    it "includes data when present" do
      klass = Class.new(FakeMcpController)
      tool = Class.new do
        def self.tool_name = "with_data"
        def self.descriptor = { name: "with_data" }
        def self.call(_args)
          raise PersonalAppClient::Rails::McpDispatch::JsonRpcError.new(-32000, "custom", { hint: "x" })
        end
      end
      registry = Module.new do
        define_singleton_method(:descriptors) { [ tool.descriptor ] }
        define_singleton_method(:find) { |name| name == "with_data" ? tool : nil }
      end
      klass.mcp_config server_name: "s", tool_registry: registry
      c = klass.new
      c.request = OpenStruct.new(request_parameters: {
        "method" => "tools/call", "id" => 9, "params" => { "name" => "with_data" }
      })
      c.handle
      expect(c.rendered[:json][:error]).to eq(code: -32000, message: "custom", data: { hint: "x" })
    end
  end
end
