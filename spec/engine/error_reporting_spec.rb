RSpec.describe "error reporting" do
  let(:delivered) { Dummy::DELIVERED_ERRORS }

  it "reports an unhandled controller exception once, with where it happened" do
    get_html "/boom"
    expect(last_response.status).to eq(500)
    expect(delivered.size).to eq(1)
    event = delivered.first
    expect(event).to include(
      kind: "server", error_class: "NoMethodError", origin: "PagesController#boom",
      path: "/boom", request_method: "GET", handled: false, severity: "error",
      source: "application.action_dispatch", count: 1
    )
    expect(event[:message]).to include("frobnicate")
    expect(event[:location]).to start_with("app/controllers/pages_controller.rb:")
    expect(event[:fingerprint]).to match(/\A\h{16}\z/)
    expect(event[:occurred_at]).to match(/\A\d{4}-\d\d-\d\dT/)
    expect(event.keys - PersonalAppClient::HubClient::ERROR_EVENT_KEYS).to eq([])
  end

  it "counts repeats inside the window instead of sending them" do
    3.times { get_html "/boom" }
    expect(delivered.size).to eq(1)
  end

  it "sends the suppressed count once the window has passed" do
    now = 1_000.0
    PersonalAppClient::ErrorReporting.uninstall!
    PersonalAppClient::ErrorReporting.install!(clock: -> { now })
    3.times { get_html "/boom" }
    now += PersonalAppClient.config.error_reporting.window + 1
    get_html "/boom"
    expect(delivered.map { |e| e[:count] }).to eq([ 1, 3 ])
  ensure
    PersonalAppClient::ErrorReporting.uninstall!
    PersonalAppClient::ErrorReporting.install!
  end

  it "reports a rendered 5xx (no exception) as HTTP <status>" do
    get "/rendered-500"
    expect(last_response.status).to eq(500)
    expect(delivered.map { |e| e.slice(:error_class, :origin, :status, :path) }).to eq([
      { error_class: "HTTP 500", origin: "PagesController#rendered_500", status: 500, path: "/rendered-500" }
    ])
  end

  it "ignores a 404 from RecordNotFound" do
    get_html "/missing"
    expect(last_response.status).to eq(404)
    expect(delivered).to be_empty
  end

  it "reports Rails.error.report at severity error, not handled warnings" do
    Rails.error.handle { raise "swallowed" }
    expect(delivered).to be_empty
    Rails.error.report(RuntimeError.new("job went wrong"), handled: false, source: "application.active_job")
    expect(delivered.map { |e| e.slice(:kind, :message) }).to eq([ { kind: "job", message: "job went wrong" } ])
  end

  it "never raises when delivery fails" do
    via = PersonalAppClient.config.error_reporting.via
    PersonalAppClient.config.error_reporting.via = ->(_payload) { raise "base is down" }
    expect { get_html "/boom" }.not_to raise_error
    expect(last_response.status).to eq(500)
  ensure
    PersonalAppClient.config.error_reporting.via = via
  end

  it "does not report errors raised while delivering (no loops)" do
    via = PersonalAppClient.config.error_reporting.via
    PersonalAppClient.config.error_reporting.via = lambda do |payload|
      Dummy::DELIVERED_ERRORS << payload
      Rails.error.report(RuntimeError.new("inside delivery"), handled: false)
    end
    get_html "/boom"
    expect(delivered.map { |e| e[:message] }).to eq([ "undefined method 'frobnicate' for nil (item 42)" ])
  ensure
    PersonalAppClient.config.error_reporting.via = via
  end

  it "delivers on a background thread when async" do
    PersonalAppClient.config.error_reporting.async = true
    get_html "/boom"
    Timeout.timeout(5) { sleep 0.01 while delivered.empty? }
    expect(delivered.first[:error_class]).to eq("NoMethodError")
  ensure
    PersonalAppClient.config.error_reporting.async = false
  end

  describe "POST /api/csp-reports" do
    let(:violation) do
      { "csp-report" => {
        "document-uri" => "https://budgeter.joenguyen.ca/transactions?x=1",
        "violated-directive" => "script-src-elem", "effective-directive" => "script-src-elem",
        "blocked-uri" => "https://evil.example/x.js?a=1", "disposition" => "report",
        "source-file" => "https://budgeter.joenguyen.ca/transactions", "line-number" => 12
      } }
    end

    it "reports a violation as a CSPViolation error, one row per directive, origin and page" do
      post "/api/csp-reports", violation.to_json, { "CONTENT_TYPE" => "application/csp-report" }
      expect(last_response.status).to eq(204)
      expect(delivered.first).to include(
        error_class: "CSPViolation", message: "script-src-elem blocked https://evil.example",
        path: "/transactions", source: "csp.report", handled: true
      )
    end

    it "answers 204 and drops a body that is not a report" do
      post "/api/csp-reports", "not json", { "CONTENT_TYPE" => "application/csp-report" }
      post "/api/csp-reports", { "csp-report" => {} }.to_json, { "CONTENT_TYPE" => "application/csp-report" }
      expect(last_response.status).to eq(204)
      expect(delivered).to be_empty
    end
  end

  describe "POST /api/client-errors" do
    let(:report) do
      { kind: "error", message: "Uncaught TypeError: Cannot read properties of null (reading 'value')",
        source: "http://example.org/assets/budgeter-abc123.js?v=1", line: 41, col: 12,
        stack: "TypeError: Cannot read properties of null\n    at render (budgeter.js:41:12)", url: "/transactions" }
    end

    it "reports a browser error" do
      post "/api/client-errors", report.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(204)
      expect(delivered.first).to include(
        kind: "client", error_class: "TypeError", origin: "browser", path: "/transactions",
        location: "/assets/budgeter-abc123.js:41:12", source: "window.error",
        message: "Cannot read properties of null (reading 'value')"
      )
    end

    it "answers 204 and drops an empty or oversized report" do
      post "/api/client-errors", {}.to_json, { "CONTENT_TYPE" => "application/json" }
      post "/api/client-errors", report.merge(stack: "x" * 20_000).to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(204)
      expect(delivered).to be_empty
    end

    it "needs no CSRF token (sendBeacon cannot send one)" do
      post "/api/client-errors", report.to_json, { "CONTENT_TYPE" => "application/json", "HTTP_USER_AGENT" => PersonalAppClient::TestSupport::MODERN_UA }
      expect(last_response.status).to eq(204)
    end

    it "is a no-op when reporting is off" do
      PersonalAppClient::ErrorReporting.uninstall!
      post "/api/client-errors", report.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(204)
      expect(delivered).to be_empty
    ensure
      PersonalAppClient::ErrorReporting.install!
    end
  end
end
