RSpec.describe "default controllers" do
  describe "MCP (POST /api/mcp)" do
    it "speaks JSON-RPC as <app>-mcp with the app's tool registry" do
      body = mcp_post("initialize")
      expect(body.dig("result", "serverInfo", "name")).to eq("dummy-mcp")
      expect(mcp_post("tools/list").dig("result", "tools").map { |t| t["name"] }).to eq(%w[echo crash picky])
      result = mcp_post("tools/call", name: "echo", arguments: { "a" => 1 })
      expect(JSON.parse(result.dig("result", "content", 0, "text"))).to eq("echoed" => { "a" => 1 })
    end

    it "requires the OAuth bearer or shared key" do
      post "/api/mcp", { jsonrpc: "2.0", id: 1, method: "ping" }.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(401)
      expect(json).to eq("error" => "unauthorized")
    end

    it "inherits the app's Api::BaseController" do
      mcp_post("ping")
      expect(last_response.headers["X-Dummy-Api-Base"]).to eq("1")
      expect(PersonalAppClient::McpController.superclass).to eq(Api::BaseController)
    end
  end

  describe "health (GET /api/health/inter-app)" do
    it "renders the v0.7.0 payload with the configured targets" do
      allow_any_instance_of(BaseAppClient).to receive(:ping).and_return(success: true, status: 200)
      get "/api/health/inter-app"
      expect(last_response.status).to eq(200)
      expect(json.keys).to eq(%w[ok checked_at revision targets])
      expect(json["targets"].map { |t| t.slice("name", "status") }).to eq([ { "name" => "base", "status" => "ok" } ])
      expect(json["ok"]).to be(true)
    end

    it "reports a failing target" do
      allow_any_instance_of(BaseAppClient).to receive(:ping).and_return(success: false, error: "HTTP 502")
      get "/api/health/inter-app"
      expect(json["ok"]).to be(false)
      expect(json["targets"].first).to include("status" => "error", "error" => "HTTP 502")
    end

    it "has no targets without config.health_targets" do
      targets = PersonalAppClient.config.health_targets
      PersonalAppClient.config.health_targets = nil
      get "/api/health/inter-app"
      expect(json["targets"]).to eq([])
    ensure
      PersonalAppClient.config.health_targets = targets
    end

    it "rejects a wrong X-App-Auth (InterAppAuthOptional, as before)" do
      get "/api/health/inter-app", {}, { "HTTP_X_APP_AUTH" => "nope" }
      expect(last_response.status).to eq(401)
    end
  end

  describe "backups (/api/backup/*)" do
    after { Dir[Rails.root.join("tmp", "dummy_backup_*.zip")].each { |f| File.delete(f) } }

    it "creates, lists, downloads and restores with prefix = app_id" do
      ActiveRecord::Base.connection.execute("DELETE FROM notes")
      ActiveRecord::Base.connection.execute("INSERT INTO notes (body) VALUES ('kept by the backup')")

      get "/api/backup/create"
      expect(last_response.status).to eq(200), last_response.body
      filename = json["filename"]
      expect(filename).to match(/\Adummy_backup_\d{8}_\d{6}\.zip\z/)

      require "zip"
      Zip::File.open(Rails.root.join("tmp", filename).to_s) do |zip|
        expect(zip.entries.map(&:name)).to include("dummy.db", "README.md")
      end

      get "/api/backup/list"
      expect(json.map { |b| b["filename"] }).to include(filename)

      get "/api/backup/download/#{filename}"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("zip")

      ActiveRecord::Base.connection.execute("INSERT INTO notes (body) VALUES ('added after')")
      post "/api/backup/restore", { filename: filename }.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200), "#{last_response.status}: #{Dummy::DELIVERED_ERRORS.inspect}"
      expect(ActiveRecord::Base.connection.select_values("SELECT body FROM notes")).to eq([ "kept by the backup" ])
    end

    it "is operator-only in production" do
      allow(Rails.env).to receive(:production?).and_return(true)
      get "/api/backup/list"
      expect(last_response.status).to eq(401)
      get "/api/backup/list", {}, secret_headers
      expect(last_response.status).to eq(200)
    end
  end

  describe "well-known (GET /.well-known/oauth-protected-resource)" do
    it "points MCP clients at base" do
      get "/.well-known/oauth-protected-resource"
      expect(json).to eq(
        "resource" => "http://example.org/api/mcp",
        "authorization_servers" => [ "https://base.joenguyen.ca" ],
        "scopes_supported" => [ "mcp" ],
        "bearer_methods_supported" => [ "header" ]
      )
    end
  end

  describe "up" do
    it "is Rails' health check" do
      get "/up"
      expect(last_response.status).to eq(200)
    end
  end

  describe "api_base_controller" do
    around do |example|
      previous = PersonalAppClient.config.api_base_controller
      example.run
    ensure
      PersonalAppClient.config.api_base_controller = previous
    end

    it "falls back to the engine's ApiController when the app has no Api::BaseController" do
      PersonalAppClient.config.api_base_controller = "Api::BaseController"
      allow(ActiveSupport::Inflector).to receive(:safe_constantize).and_call_original
      allow_any_instance_of(String).to receive(:safe_constantize).and_wrap_original do |m|
        m.receiver == "Api::BaseController" ? nil : m.call
      end
      expect(PersonalAppClient.api_base_controller).to eq(PersonalAppClient::ApiController)
    end

    it "raises for a misspelt custom parent" do
      PersonalAppClient.config.api_base_controller = "Api::Nope"
      expect { PersonalAppClient.api_base_controller }.to raise_error(NameError, /Api::Nope/)
    end
  end
end
