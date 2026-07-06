require "active_support"
require "active_support/time"
require "personal_app_client/mcp/base_tool"

class FakeEchoTool < PersonalAppClient::Mcp::BaseTool
  class << self
    def tool_name = "echo"
    def description = "Echoes back the arguments"
    def input_schema
      { type: "object", properties: { text: { type: "string" } } }
    end

    def call(args)
      { echoed: args["text"] }
    end
  end
end

RSpec.describe PersonalAppClient::Mcp::BaseTool do
  describe "abstract interface" do
    it "raises NotImplementedError for tool_name" do
      expect { described_class.tool_name }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError for description" do
      expect { described_class.description }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError for call" do
      expect { described_class.call({}) }.to raise_error(NotImplementedError)
    end

    it "defaults input_schema to an empty object schema" do
      expect(described_class.input_schema).to eq(type: "object", properties: {})
    end
  end

  describe ".descriptor" do
    it "builds the MCP descriptor from the class metadata" do
      expect(FakeEchoTool.descriptor).to eq(
        name: "echo",
        description: "Echoes back the arguments",
        inputSchema: { type: "object", properties: { text: { type: "string" } } }
      )
    end
  end

  describe ".parse_date" do
    it "parses ISO dates" do
      expect(described_class.parse_date("2026-07-06")).to eq(Date.new(2026, 7, 6))
    end

    it "returns the default when blank" do
      expect(described_class.parse_date(nil, default: :fallback)).to eq(:fallback)
      expect(described_class.parse_date("", default: :fallback)).to eq(:fallback)
    end

    it "raises ArgumentError with a helpful message on garbage" do
      expect { described_class.parse_date("not-a-date") }
        .to raise_error(ArgumentError, /Invalid date/)
    end
  end

  describe ".parse_time" do
    around do |example|
      previous = Time.zone
      Time.zone = "UTC"
      example.run
      Time.zone = previous
    end

    it "parses timestamps in the app time zone" do
      expect(described_class.parse_time("2026-07-06 10:30")).to eq(Time.zone.parse("2026-07-06 10:30"))
    end

    it "returns nil when blank" do
      expect(described_class.parse_time(nil)).to be_nil
    end

    it "raises ArgumentError on garbage" do
      expect { described_class.parse_time("nope") }.to raise_error(ArgumentError, /Invalid timestamp/)
    end
  end

  describe ".clamp_int" do
    it "returns the value when in range" do
      expect(described_class.clamp_int(42, default: 10)).to eq(42)
    end

    it "falls back to the default when non-positive" do
      expect(described_class.clamp_int(0, default: 10)).to eq(10)
      expect(described_class.clamp_int(nil, default: 10)).to eq(10)
    end

    it "clamps to max (default 100)" do
      expect(described_class.clamp_int(9999, default: 10)).to eq(100)
      expect(described_class.clamp_int(9999, default: 10, max: 200)).to eq(200)
    end
  end
end
