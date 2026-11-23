module Mcp
  module Tools
    class PickyTool < PersonalAppClient::Mcp::BaseTool
      def self.tool_name = "picky"
      def self.description = "Rejects every argument."
      def self.input_schema = { type: "object", properties: {} }
      def self.call(_args) = raise(ArgumentError, "date must be YYYY-MM-DD")
    end
  end
end
