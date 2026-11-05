module PersonalAppClient
  module Mcp
    # The lookup methods every app's Mcp::ToolRegistry repeated, derived from
    # its one TOOLS constant:
    #
    #     module Mcp
    #       module ToolRegistry
    #         extend PersonalAppClient::Mcp::Registry
    #
    #         TOOLS = [ Tools::ListItems, Tools::GetItem ].freeze
    #       end
    #     end
    #
    #   ToolRegistry.tools        TOOLS
    #   ToolRegistry.descriptors  what McpDispatch returns for tools/list
    #   ToolRegistry.find(name)   what McpDispatch calls for tools/call (nil if unknown)
    #   ToolRegistry.tool_names   [ "list_items", "get_item" ]
    #
    # TOOLS is read on each call, so `extend` may come before or after the
    # constant and Zeitwerk reloading keeps working.
    module Registry
      def tools
        const_get(:TOOLS)
      end

      def descriptors
        tools.map(&:descriptor)
      end

      def find(name)
        tools.find { |tool| tool.tool_name == name }
      end

      def tool_names
        tools.map(&:tool_name)
      end
    end
  end
end
