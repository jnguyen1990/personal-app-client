require "active_support/concern"
require "active_support/core_ext/string/inflections"
require "json"

module PersonalAppClient
  module Rails
    # Concern implementing the MCP (Model Context Protocol) Streamable HTTP
    # endpoint shared by the personal apps. Speaks JSON-RPC 2.0 so Claude
    # Desktop / claude.ai can discover & call tools registered in the app's
    # tool registry (an object responding to `descriptors` and `find(name)`).
    #
    # Authentication is NOT handled here — compose with one of the auth
    # concerns (OauthResourceServer, ApiKeyAuth) exactly as before:
    #
    #     class Api::McpController < BaseController
    #       include PersonalAppClient::Rails::McpDispatch
    #       include PersonalAppClient::Rails::OauthResourceServer
    #
    #       mcp_config server_name: "base-mcp", tool_registry: "Mcp::ToolRegistry"
    #     end
    #
    # `tool_registry` may be a module/class, a String (constantized lazily so
    # Zeitwerk reloading keeps working), or a Proc returning the registry.
    # With no registry configured, `tools/list` returns `[]` and `tools/call`
    # raises -32601 with `no_tools_message`.
    module McpDispatch
      extend ActiveSupport::Concern

      DEFAULT_PROTOCOL_VERSION = "2025-06-18".freeze
      DEFAULT_SERVER_VERSION = "0.1.0".freeze

      class JsonRpcError < StandardError
        attr_reader :code, :data
        def initialize(code, message, data = nil)
          super(message)
          @code = code
          @data = data
        end
      end

      class_methods do
        attr_accessor :mcp_server_name, :mcp_server_version, :mcp_protocol_version,
                      :mcp_tool_registry, :mcp_no_tools_message

        def mcp_config(server_name:, server_version: DEFAULT_SERVER_VERSION,
                       protocol_version: DEFAULT_PROTOCOL_VERSION,
                       tool_registry: nil, no_tools_message: nil)
          self.mcp_server_name = server_name
          self.mcp_server_version = server_version
          self.mcp_protocol_version = protocol_version
          self.mcp_tool_registry = tool_registry
          self.mcp_no_tools_message = no_tools_message
        end
      end

      def handle
        req = request.request_parameters
        method = req["method"]
        id = req["id"]
        params = req["params"] || {}

        # Notifications have no id and expect no response body (spec).
        if id.nil? && method.to_s.start_with?("notifications/")
          head :accepted
          return
        end

        result = dispatch_rpc(method, params)
        render json: { jsonrpc: "2.0", id: id, result: result }
      rescue JsonRpcError => e
        render json: {
          jsonrpc: "2.0",
          id: req["id"],
          error: { code: e.code, message: e.message, data: e.data }.compact
        }
      rescue => e
        ::Rails.logger.error("[MCP] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        render json: {
          jsonrpc: "2.0",
          id: req["id"],
          error: { code: -32603, message: "Internal error: #{e.message}" }
        }
      end

      private

      def dispatch_rpc(method, params)
        case method
        when "initialize"
          {
            protocolVersion: self.class.mcp_protocol_version,
            capabilities: { tools: {} },
            serverInfo: { name: self.class.mcp_server_name, version: self.class.mcp_server_version }
          }
        when "tools/list"
          registry = mcp_registry
          { tools: registry ? registry.descriptors : [] }
        when "tools/call"
          registry = mcp_registry
          unless registry
            raise JsonRpcError.new(-32601, self.class.mcp_no_tools_message || "No tools registered")
          end
          name = params["name"]
          args = params["arguments"] || {}
          tool = registry.find(name)
          raise JsonRpcError.new(-32602, "Unknown tool: #{name}") unless tool
          payload = tool.call(args)
          { content: [ { type: "text", text: payload.is_a?(String) ? payload : JSON.pretty_generate(payload) } ] }
        when "ping"
          {}
        else
          raise JsonRpcError.new(-32601, "Method not found: #{method}")
        end
      end

      def mcp_registry
        registry = self.class.mcp_tool_registry
        case registry
        when nil then nil
        when Proc then registry.call
        when String then registry.constantize
        else registry
        end
      end
    end
  end
end
