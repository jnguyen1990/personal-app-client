module PersonalAppClient
  # Default POST /api/mcp: the MCP JSON-RPC endpoint (McpDispatch) behind
  # OAuth 2.1 with base as the Authorization Server (OauthResourceServer).
  # Server name config.mcp_server_name ("<app_id>-mcp"), tools from
  # config.mcp_tool_registry ("Mcp::ToolRegistry").
  #
  # Replace it with `personal_app_routes mcp: "api/mcp"` and a controller of
  # your own.
  class McpController < PersonalAppClient.api_base_controller
    include PersonalAppClient::Rails::McpDispatch
    include PersonalAppClient::Rails::OauthResourceServer

    mcp_config server_name: PersonalAppClient.config.mcp_server_name,
               tool_registry: PersonalAppClient.config.mcp_tool_registry
  end
end
