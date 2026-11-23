module Mcp
  module Tools
    class CrashTool < PersonalAppClient::Mcp::BaseTool
      def self.tool_name = "crash"
      def self.description = "Always raises."
      def self.input_schema = { type: "object", properties: {} }
      def self.call(_args) = raise(ZeroDivisionError, "divided by 0")
    end
  end
end
