require "open3"
require "tmpdir"
require "webrick"
require "rack/mock"
require_relative "../support/stub_server"

# postings stays on v0.7.0 while the other five move to v0.8.0. These run the
# REAL v0.7.0 code (extracted from the git tag) against v0.8.0:
#
#   * a v0.7.0 app calling an upgraded sibling — the v0.7.0 Client against
#     the dummy app's engine-drawn endpoints, over HTTP;
#   * an upgraded app calling base the way a v0.7.0 app does — v0.7.0 and
#     v0.8.0 HubClient send byte-for-byte the same requests.
#
# Skipped when the tag is not in the checkout (a shallow CI clone).
RSpec.describe "interoperability with v0.7.0" do
  gem_root = File.expand_path("../..", __dir__)
  tag_present = system("git", "-C", gem_root, "rev-parse", "--verify", "--quiet", "v0.7.0^{commit}",
                       out: File::NULL, err: File::NULL)

  before(:all) do
    skip "v0.7.0 tag not available" unless tag_present

    @v070 = Dir.mktmpdir("pac-v070")
    archive, status = Open3.capture2("git", "-C", gem_root, "archive", "v0.7.0", "lib", binmode: true)
    raise "git archive failed" unless status.success?
    Open3.capture2("tar", "-x", "-C", @v070, stdin_data: archive, binmode: true)

    @server = RailsBridge.new(Rails.application)
  end

  after(:all) do
    @server&.stop
    FileUtils.rm_rf(@v070) if @v070
  end

  # Runs `code` in a fresh Ruby with v0.7.0 loaded, returns its JSON output.
  def v070(code)
    script = <<~RUBY
      require "json"
      require #{File.join(@v070, 'lib', 'personal_app_client').inspect}
      abort "loaded \#{PersonalAppClient::VERSION}, not 0.7.0" unless PersonalAppClient::VERSION == "0.7.0"
      result = begin
        #{code}
      rescue PersonalAppClient::ResponseError => e
        { "error" => e.class.name, "status" => e.status }
      end
      puts JSON.generate(result)
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script)
    raise "v0.7.0 subprocess failed: #{err}" unless status.success?
    JSON.parse(out.lines.last)
  end

  def client(secret = ENV["INTER_APP_SECRET"])
    "PersonalAppClient::Client.new(base_url: #{@server.url.inspect}, secret: #{secret.inspect}, env: 'development')"
  end

  it "v0.7.0 Client reads an upgraded sibling's /up" do
    expect(v070("#{client}.get('/up'); { 'status' => 200 }")).to eq("status" => 200)
  end

  it "v0.7.0 Client gets the health payload shape base's cluster view parses" do
    allow_any_instance_of(BaseAppClient).to receive(:ping).and_return(success: true, status: 200)
    body = v070("#{client}.get('/api/health/inter-app')")
    expect(body.keys).to eq(%w[ok checked_at revision targets])
    expect(body["targets"].map { |t| t["name"] }).to eq([ "base" ])
  end

  it "X-App-Auth is still checked the same way (a wrong secret is a 401)" do
    expect(v070("#{client('wrong-secret')}.get('/api/health/inter-app')"))
      .to eq("error" => "PersonalAppClient::ResponseError", "status" => 401)
  end

  it "the mini's backup pull (X-App-Auth on /api/backup/*) still works in production" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(v070("#{client}.get('/api/backup/list')")).to be_an(Array)
    expect(v070("#{client('wrong')}.get('/api/backup/list')")).to include("status" => 401)
  end

  it "the protected-resource metadata is unchanged" do
    body = v070("#{client}.get('/.well-known/oauth-protected-resource')")
    expect(body).to include("authorization_servers" => [ "https://base.joenguyen.ca" ], "scopes_supported" => [ "mcp" ])
  end

  describe "talking to base" do
    let(:stub) { StubServer.new }

    after { stub.stop }

    def capture_requests(&block)
      stub.on(:post, :any) { |_req, res| res.status = 200; res.body = "{}" }
      block.call
      stub.requests.map { |r| r.slice(:method, :path).merge(body: JSON.parse(r[:body]), auth: r[:headers]["x-app-auth"]) }
    end

    it "v0.8.0 HubClient sends exactly what v0.7.0 sends for reminders and job statuses" do
      calls = <<~RUBY
        hub = PersonalAppClient::HubClient.new(source_app: "postings", base_url: #{stub.url.inspect}, secret: "s3cret", env: "development")
        hub.sync_reminder(source_id: "closing-7", title: "Apply", description: "closes Friday", starts_on: "2026-11-27")
        hub.delete_reminder("closing-7")
        hub.report_job_status(name: "postings sweep", status: "ok", cadence: "daily", detail: "3 new")
      RUBY

      old = capture_requests { v070("#{calls}; true") }
      stub.requests.clear
      new = capture_requests { eval(calls) } # rubocop:disable Security/Eval

      expect(new).to eq(old)
      expect(new.map { |r| r[:path] }).to eq(%w[/api/reminders/sync /api/reminders/sync /api/job-statuses/sync])
    end

    it "the payload keys base accepts are the same lists" do
      old = v070("{ 'r' => PersonalAppClient::HubClient::REMINDER_KEYS, 'j' => PersonalAppClient::HubClient::JOB_STATUS_KEYS }")
      expect(PersonalAppClient::HubClient::REMINDER_KEYS.map(&:to_s)).to eq(old["r"])
      expect(PersonalAppClient::HubClient::JOB_STATUS_KEYS.map(&:to_s)).to eq(old["j"])
    end
  end

  # A Rails app over real HTTP (WEBrick → Rack), so the v0.7.0 client in
  # another process can reach it.
  class RailsBridge
    def initialize(app)
      @app = app
      @server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1",
                                        Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
      @server.mount_proc("/") { |req, res| bridge(req, res) }
      @thread = Thread.new { @server.start }
      sleep 0.01 until @server.status == :Running
    end

    def url
      "http://127.0.0.1:#{@server.config[:Port]}"
    end

    def stop
      @server.shutdown
      @thread.join(2)
    end

    private

    def bridge(req, res)
      env = Rack::MockRequest.env_for(req.request_uri.to_s, method: req.request_method, input: req.body.to_s)
      req.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
      env["CONTENT_TYPE"] = req["content-type"] if req["content-type"]
      status, headers, body = @app.call(env)
      res.status = status
      headers.each { |k, v| res[k] = v }
      res.body = +""
      body.each { |chunk| res.body << chunk }
      body.close if body.respond_to?(:close)
    end
  end
end
