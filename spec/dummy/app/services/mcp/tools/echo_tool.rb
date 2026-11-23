module Mcp
  module Tools
    class EchoTool < PersonalAppClient::Mcp::BaseTool
      def self.tool_name = "echo"
      def self.description = "Echo the arguments back. Second sentence is not shown."
      def self.input_schema = { type: "object", properties: {} }
      def self.call(args) = { echoed: args }
    end
  end
end
