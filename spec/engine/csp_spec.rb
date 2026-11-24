require "nokogiri"

# PLAT-25 / PLAT-11.
RSpec.describe "content security policy and vendored libraries" do
  # Stands in for Rails' app.config: content_security_policy takes a block.
  fake_config = Class.new do
    attr_accessor :content_security_policy_report_only
    def initialize(policy = nil) = @policy = policy
    def content_security_policy(&block)
      @policy = ActionDispatch::ContentSecurityPolicy.new(&block) if block
      @policy
    end
  end
  define_method(:fake_app) { |policy = nil| Struct.new(:config).new(fake_config.new(policy)) }

  it "sends a report-only policy by default, limited to the app and the design-system host" do
    get_html "/"
    header = last_response.headers["Content-Security-Policy-Report-Only"]
    expect(header).to be_present
    expect(last_response.headers["Content-Security-Policy"]).to be_nil
    directives = header.split(";").map(&:strip).to_h { |d| [ d.split.first, d.split.drop(1) ] }
    expect(directives["script-src"]).to eq([ "'self'", "'unsafe-inline'", "https://design-system.joenguyen.ca" ])
    expect(directives["connect-src"]).to eq([ "'self'", "https://design-system.joenguyen.ca" ])
    expect(directives["object-src"]).to eq([ "'none'" ])
    expect(directives["report-uri"]).to eq([ "/api/csp-reports" ])
  end

  it "builds the enforcing policy with any extra source an app adds" do
    config = PersonalAppClient::Configuration.new
    config.content_security_policy_extra = ->(p) { p.connect_src :self, "https://api.example.test" }
    policy = PersonalAppClient::Csp.build(config)
    expect(policy.build(nil)).to include("connect-src 'self' https://api.example.test")
  end

  it "leaves an app's own policy alone" do
    app = fake_app(:mine)
    expect(PersonalAppClient::Csp.apply!(app)).to be_nil
    expect(app.config.content_security_policy).to eq(:mine)
  end

  it "does nothing when switched off" do
    config = PersonalAppClient::Configuration.new
    config.content_security_policy = false
    app = fake_app
    expect(PersonalAppClient::Csp.apply!(app, config)).to be_nil
    expect(app.config.content_security_policy).to be_nil
  end

  it "sets report_only false for :enforce" do
    config = PersonalAppClient::Configuration.new
    config.content_security_policy = :enforce
    app = fake_app
    PersonalAppClient::Csp.apply!(app, config)
    expect(app.config.content_security_policy_report_only).to be(false)
    expect(app.config.content_security_policy.build(nil)).to include("script-src 'self' 'unsafe-inline' https://design-system.joenguyen.ca")
  end

  describe "vendored libraries" do
    let(:view) do
      Class.new(ActionView::Base) { include PersonalAppClient::ShellHelper }.empty
    end

    it "emits pinned tags on the design-system host with integrity" do
      html = Nokogiri::HTML.fragment(view.personal_app_vendor_tags("chart.js", "leaflet.css"))
      script = html.at("script")
      expect(script["src"]).to eq("https://design-system.joenguyen.ca/vendor/chart.js-4.6.1/chart.umd.min.js")
      expect(script["integrity"]).to start_with("sha384-")
      expect(script["crossorigin"]).to eq("anonymous")
      expect(html.at("link")["href"]).to end_with("/vendor/leaflet-1.9.4/leaflet.css")
    end

    it "describes libraries as JSON for loading on demand, and refuses unknown names" do
      data = JSON.parse(view.personal_app_vendor_json("leaflet.js"))
      expect(data["leaflet.js"]["url"]).to end_with("/vendor/leaflet-1.9.4/leaflet.js")
      expect { view.personal_app_vendor_tags("jquery") }.to raise_error(ArgumentError, /unknown vendored library/)
    end
  end
end
