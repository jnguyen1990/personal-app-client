require "json"

module PersonalAppClient
  # Helpers for the apps' test suites (Minitest integration tests):
  #
  #     # test/test_helper.rb
  #     require "personal_app_client/test_support"
  #
  #     PersonalAppClient::TestSupport.block_network!
  #
  #     class ActionDispatch::IntegrationTest
  #       include PersonalAppClient::TestSupport
  #     end
  #
  # Nothing here depends on Minitest or Rails being loaded; the request
  # helpers only need the `post` / `response` an integration test provides.
  module TestSupport
    # ApplicationController uses `allow_browser versions: :modern` — a modern
    # UA keeps requests from being rejected with 406.
    MODERN_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36".freeze

    MCP_PATH = "/api/mcp".freeze

    # Turn on WebMock's block on real HTTP if WebMock is loaded (localhost
    # stays open so system/integration tests can reach the app server).
    # Returns true when the block is on, false when WebMock is not loaded.
    def self.block_network!(allow_localhost: true, **options)
      return false unless defined?(::WebMock)
      ::WebMock.disable_net_connect!(allow_localhost: allow_localhost, **options)
      true
    end

    def json_headers
      { "Content-Type" => "application/json", "HTTP_USER_AGENT" => MODERN_UA }
    end

    # Headers for inter-app calls (X-App-Auth) — for routes called by sibling
    # apps, and for OperatorAuth-guarded routes. Pass json: true to add the
    # JSON content type when the test posts a `.to_json` body.
    def inter_app_headers(json: false)
      headers = { "X-App-Auth" => ENV["INTER_APP_SECRET"] }
      json ? json_headers.merge(headers) : headers
    end

    # Headers for /api/mcp via the shared-key path of the auth concerns.
    def mcp_headers
      json_headers.merge("X-API-Key" => mcp_api_key)
    end

    # POST a JSON-RPC envelope against /api/mcp and return the parsed body.
    #
    #     mcp_call("tools/call", name: "list_items", arguments: {})
    def mcp_call(method, params = {})
      post MCP_PATH,
           params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
           headers: mcp_headers
      JSON.parse(response.body)
    end

    # Parse the JSON text payload out of a successful tools/call response.
    def mcp_tool_result(body)
      JSON.parse(body.dig("result", "content", 0, "text"))
    end

    private

    # The ENV key the auth concerns check first, else Rails credentials, else
    # a fixed test value.
    def mcp_api_key
      key = ENV["MCP_API_KEY"].to_s
      return key unless key.empty?
      if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application.respond_to?(:credentials)
        from_credentials = ::Rails.application.credentials.dig(:mcp, :api_key)
        return from_credentials if from_credentials
      end
      "test-mcp-key"
    end
  end
end
