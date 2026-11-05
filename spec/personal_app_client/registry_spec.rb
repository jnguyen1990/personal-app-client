require "personal_app_client/mcp/base_tool"
require "personal_app_client/mcp/registry"

module RegistrySpec
  class ListItems < PersonalAppClient::Mcp::BaseTool
    def self.tool_name = "list_items"
    def self.description = "List items"
    def self.call(_args) = { items: [] }
  end

  class GetItem < PersonalAppClient::Mcp::BaseTool
    def self.tool_name = "get_item"
    def self.description = "Get one item"
    def self.input_schema = { type: "object", properties: { id: { type: "integer" } } }
  end

  # `extend` before the constant, as an app would write it.
  module ToolRegistry
    extend PersonalAppClient::Mcp::Registry

    TOOLS = [ ListItems, GetItem ].freeze
  end
end

RSpec.describe PersonalAppClient::Mcp::Registry do
  let(:registry) { RegistrySpec::ToolRegistry }

  it "exposes TOOLS as .tools without hiding the constant" do
    expect(registry.tools).to equal(RegistrySpec::ToolRegistry::TOOLS)
  end

  it "builds descriptors for tools/list" do
    expect(registry.descriptors).to eq([
      { name: "list_items", description: "List items", inputSchema: { type: "object", properties: {} } },
      { name: "get_item", description: "Get one item",
        inputSchema: { type: "object", properties: { id: { type: "integer" } } } }
    ])
  end

  it "finds a tool by name, nil when unknown" do
    expect(registry.find("get_item")).to eq(RegistrySpec::GetItem)
    expect(registry.find("nope")).to be_nil
    expect(registry.find(nil)).to be_nil
  end

  it "lists tool names" do
    expect(registry.tool_names).to eq(%w[list_items get_item])
  end

  it "satisfies the contract McpDispatch relies on" do
    expect(registry).to respond_to(:descriptors, :find)
    expect(registry.find("list_items").call({})).to eq(items: [])
  end

  it "fails loudly when the module has no TOOLS" do
    empty = Module.new { extend PersonalAppClient::Mcp::Registry }
    expect { empty.descriptors }.to raise_error(NameError, /TOOLS/)
  end
end
