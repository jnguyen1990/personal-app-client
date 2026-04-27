RSpec.describe PersonalAppClient::Client do
  let(:server) { StubServer.new }
  after { server.stop if defined?(@server) || server }

  describe "URL guard" do
    it "refuses *.joenguyen.ca in production" do
      expect {
        described_class.new(base_url: "https://fitness.joenguyen.ca", env: "production")
      }.to raise_error(PersonalAppClient::ConfigurationError, /Refusing to use public/)
    end

    it "permits *.joenguyen.ca in development" do
      expect {
        described_class.new(base_url: "https://fitness.joenguyen.ca", env: "development")
      }.not_to raise_error
    end

    it "permits Tailscale URL in production" do
      expect {
        described_class.new(base_url: "http://fitness.tail5ece07.ts.net:3002", env: "production")
      }.not_to raise_error
    end

    it "rejects blank base_url" do
      expect {
        described_class.new(base_url: "")
      }.to raise_error(PersonalAppClient::ConfigurationError, /required/)
    end

    it "rejects non-http schemes" do
      expect {
        described_class.new(base_url: "ftp://example.com")
      }.to raise_error(PersonalAppClient::ConfigurationError, /http/)
    end

    it "respects custom guarded_domains" do
      expect {
        described_class.new(
          base_url: "https://app.example.com",
          env: "production",
          guarded_domains: [/\.example\.com\z/]
        )
      }.to raise_error(PersonalAppClient::ConfigurationError)
    end
  end

  describe "GET" do
    it "returns parsed JSON on 2xx" do
      server.on(:get, "/api/sessions") do |_req, res|
        res["Content-Type"] = "application/json"
        res.body = JSON.dump([{ "id" => 1 }])
      end
      client = described_class.new(base_url: server.url)
      expect(client.get("/api/sessions")).to eq([{ "id" => 1 }])
    end

    it "appends query params from a hash" do
      server.on(:get, "/api/sessions") do |_req, res|
        res["Content-Type"] = "application/json"
        res.body = JSON.dump(query: _req.query_string)
      end
      client = described_class.new(base_url: server.url)
      result = client.get("/api/sessions", start_date: "2026-04-27", limit: 10)
      expect(result["query"]).to include("start_date=2026-04-27")
      expect(result["query"]).to include("limit=10")
    end

    it "returns raw body when response isn't valid JSON" do
      server.on(:get, "/plain") do |_req, res|
        res["Content-Type"] = "text/plain"
        res.body = "ok"
      end
      client = described_class.new(base_url: server.url)
      expect(client.get("/plain")).to eq("ok")
    end

    it "parses JSON body even when Content-Type is absent" do
      server.on(:get, "/typeless") do |_req, res|
        res.body = "[1,2,3]"
      end
      client = described_class.new(base_url: server.url)
      expect(client.get("/typeless")).to eq([1, 2, 3])
    end
  end

  describe "non-2xx" do
    it "raises ResponseError on 500" do
      server.on(:get, "/boom") { |_req, res| res.status = 500; res.body = "kaboom" }
      client = described_class.new(base_url: server.url)
      expect { client.get("/boom") }.to raise_error(PersonalAppClient::ResponseError) do |e|
        expect(e.status).to eq(500)
        expect(e.body).to include("kaboom")
      end
    end

    it "raises ResponseError on 401" do
      server.on(:get, "/secret") { |_req, res| res.status = 401; res.body = "" }
      client = described_class.new(base_url: server.url)
      expect { client.get("/secret") }.to raise_error(PersonalAppClient::ResponseError) do |e|
        expect(e.status).to eq(401)
      end
    end

    it "hints at Cloudflare Access on 302 to cloudflareaccess.com" do
      server.on(:get, "/protected") do |_req, res|
        res.status = 302
        res["Location"] = "https://example.cloudflareaccess.com/cdn-cgi/access/login"
      end
      client = described_class.new(base_url: server.url)
      expect { client.get("/protected") }.to raise_error(PersonalAppClient::ResponseError, /Cloudflare Access/)
    end
  end

  describe "POST" do
    it "sends JSON body and parses response" do
      server.on(:post, "/api/sync") do |req, res|
        res["Content-Type"] = "application/json"
        res.status = 201
        res.body = JSON.dump(echo: JSON.parse(req.body))
      end
      client = described_class.new(base_url: server.url)
      result = client.post("/api/sync", { hello: "world" })
      expect(result).to eq("echo" => { "hello" => "world" })
    end
  end

  describe "auth header" do
    it "sends X-App-Auth when secret is set" do
      server.on(:get, "/whoami") do |req, res|
        res["Content-Type"] = "application/json"
        res.body = JSON.dump(auth: req.header["x-app-auth"]&.first)
      end
      client = described_class.new(base_url: server.url, secret: "shh")
      expect(client.get("/whoami")).to eq("auth" => "shh")
    end

    it "omits X-App-Auth when secret is nil" do
      server.on(:get, "/whoami") do |req, res|
        res["Content-Type"] = "application/json"
        res.body = JSON.dump(auth: req.header["x-app-auth"]&.first)
      end
      client = described_class.new(base_url: server.url)
      expect(client.get("/whoami")).to eq("auth" => nil)
    end
  end

  describe "connection failures" do
    it "raises ConnectionError when port is closed" do
      tcp = TCPServer.new("127.0.0.1", 0)
      port = tcp.addr[1]
      tcp.close
      client = described_class.new(base_url: "http://127.0.0.1:#{port}")
      expect { client.get("/anything") }.to raise_error(PersonalAppClient::ConnectionError)
    end
  end
end
