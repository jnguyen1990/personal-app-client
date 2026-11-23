module Mcp
  module ToolRegistry
    extend PersonalAppClient::Mcp::Registry

    TOOLS = [ Tools::EchoTool, Tools::CrashTool, Tools::PickyTool ].freeze
  end
end
