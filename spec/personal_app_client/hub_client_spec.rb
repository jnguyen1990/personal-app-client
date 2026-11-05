RSpec.describe PersonalAppClient::HubClient do
  let(:server) { StubServer.new }
  after { server.stop }

  let(:client) { described_class.new(base_url: server.url, source_app: "upkeep", env: "test", secret: "shh") }

  def last_request
    req = server.requests.last
    req.merge(json: req[:body] ? JSON.parse(req[:body]) : nil)
  end

  def answer(method, path, body = { "ok" => true })
    server.on(method, path) do |_req, res|
      res["Content-Type"] = "application/json"
      res.body = JSON.dump(body)
    end
  end

  it "is an AppClient pointed at base" do
    expect(described_class.ancestors).to include(PersonalAppClient::AppClient)
    expect(described_class.app_client_options).to include(
      setting: %w[base_app_url self_app_url], dev_url: "http://localhost:3001"
    )
  end

  describe "#sync_reminder" do
    before { answer(:post, "/api/reminders/sync", { "id" => 12 }) }

    it "POSTs the payload with this app's source_app and the inter-app secret" do
      result = client.sync_reminder(source_id: "task-7", title: "Bike: chain",
                                    description: "maintenance · due", starts_on: "2026-11-05", active: true)
      expect(result).to eq("id" => 12)
      expect(last_request).to include(method: "POST", path: "/api/reminders/sync")
      expect(last_request[:headers]["x-app-auth"]).to eq("shh")
      expect(last_request[:json]).to eq(
        "source_app" => "upkeep", "source_id" => "task-7", "title" => "Bike: chain",
        "description" => "maintenance · due", "starts_on" => "2026-11-05", "active" => true
      )
    end

    it "accepts string keys and nested steps / notifications" do
      client.sync_reminder("source_id" => "x", "title" => "t",
                           "steps" => [ { title: "one" } ], "notifications" => [ { channel: "telegram" } ])
      expect(last_request[:json]).to include("steps" => [ { "title" => "one" } ])
    end

    # base permits source_id / description; fitness sent these two for months
    # and base dropped them without a word.
    it "raises on keys base does not accept instead of letting them vanish" do
      expect { client.sync_reminder(external_id: "sync-health", title: "t", notes: "n") }
        .to raise_error(ArgumentError, /unknown reminder key\(s\) external_id, notes — base accepts .*source_id.*description/)
      expect(server.requests).to be_empty
    end

    it "requires a source_id (or id)" do
      expect { client.sync_reminder(title: "t") }.to raise_error(ArgumentError, /needs source_id/)
    end

    it "returns nil and logs when base errors" do
      server.on(:post, "/api/reminders/sync") { |_req, res| res.status = 500 }
      io = StringIO.new
      c = described_class.new(base_url: server.url, source_app: "upkeep", env: "test", logger: Logger.new(io))
      expect(c.sync_reminder(source_id: "x", title: "t")).to be_nil
      expect(io.string).to match(/HubClient: sync_reminder: HTTP 500/)
    end
  end

  describe "#delete_reminder" do
    it "POSTs a delete keyed on (source_app, source_id)" do
      answer(:post, "/api/reminders/sync", { "success" => true })
      expect(client.delete_reminder("task-7")).to eq("success" => true)
      expect(last_request[:json]).to eq(
        "action_type" => "delete", "source_app" => "upkeep", "source_id" => "task-7"
      )
    end
  end

  describe "#report_job_status" do
    before { answer(:post, "/api/job-statuses/sync", { "synced" => 1 }) }

    it "POSTs the job status" do
      client.report_job_status(name: "upkeep base sync", status: "ok", detail: "3 synced",
                               cadence: "nightly", schedule: "07:00 America/Winnipeg",
                               duration_seconds: 2, expect_within: 93_600)
      expect(last_request[:path]).to eq("/api/job-statuses/sync")
      expect(last_request[:json]).to eq(
        "name" => "upkeep base sync", "status" => "ok", "detail" => "3 synced",
        "cadence" => "nightly", "schedule" => "07:00 America/Winnipeg",
        "duration_seconds" => 2, "expect_within" => 93_600
      )
    end

    it "requires name and status" do
      expect { client.report_job_status(status: "ok") }.to raise_error(ArgumentError, /needs name/)
      expect { client.report_job_status(name: "x") }.to raise_error(ArgumentError, /needs status/)
    end

    it "raises on unknown keys" do
      expect { client.report_job_status(name: "x", status: "ok", message: "nope") }
        .to raise_error(ArgumentError, /unknown job status key\(s\) message/)
    end
  end

  describe "when unconfigured" do
    let(:client) { described_class.new(source_app: "upkeep", env: "production") }

    it "every call is a quiet nil" do
      expect(client).not_to be_configured
      expect(client.sync_reminder(source_id: "x", title: "t")).to be_nil
      expect(client.delete_reminder("x")).to be_nil
      expect(client.report_job_status(name: "x", status: "ok")).to be_nil
    end
  end

  describe "source_app" do
    it "can be set on a subclass" do
      klass = Class.new(described_class) { app_client source_app: "postings" }
      expect(klass.new(base_url: server.url, env: "test").source_app).to eq("postings")
    end

    it "defaults to the Rails application's name" do
      stub_const("Upkeep::Application", Class.new)
      allow(Rails).to receive(:application).and_return(Upkeep::Application.new)
      expect(described_class.new(base_url: server.url, env: "test").source_app).to eq("upkeep")
    end

    it "raises a ConfigurationError when it cannot be worked out" do
      allow(Rails).to receive(:application).and_return(nil)
      c = described_class.new(base_url: server.url, env: "test")
      expect { c.source_app }.to raise_error(PersonalAppClient::ConfigurationError, /source_app/)
    end
  end

  it "#ping checks base is reachable" do
    server.on(:get, "/up") { |_req, res| res.body = "ok" }
    expect(client.ping).to eq(success: true, status: 200, url: server.url)
  end
end
