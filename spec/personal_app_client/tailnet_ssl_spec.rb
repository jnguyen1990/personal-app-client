require "spec_helper"
require "personal_app_client/tailnet_ssl"

RSpec.describe PersonalAppClient::TailnetSSL do
  let(:inner) { ->(env) { [200, {}, [env["rack.url_scheme"].to_s, env["HTTPS"].to_s]] } }
  let(:mw) { described_class::AssumeSSL.new(inner) }

  def env_for(host)
    Rack::MockRequest.env_for("http://#{host}/jobs")
  end

  it "assumes https for the public host" do
    _, _, body = mw.call(env_for("base.joenguyen.ca"))
    expect(body).to eq(%w[https on])
  end

  it "leaves a tailnet request as plain http, with or without a port" do
    expect(mw.call(env_for("base.tail5ece07.ts.net:3000"))[2]).to eq(%w[http off])
    expect(mw.call(env_for("BASE.TAIL5ECE07.TS.NET"))[2].first).to eq("http")
  end

  describe ".install!" do
    let(:middleware) { double("middleware", swap: nil) }
    let(:config) { Struct.new(:assume_ssl, :force_ssl, :ssl_options, :middleware).new(true, true, {}, middleware) }
    let(:app) { double("app", config: config) }

    def request(host, path = "/jobs")
      ActionDispatch::Request.new(Rack::MockRequest.env_for("http://#{host}#{path}"))
    end

    it "swaps the middleware and exempts tailnet hosts from the https redirect" do
      described_class.install!(app)
      expect(middleware).to have_received(:swap).with(ActionDispatch::AssumeSSL, described_class::AssumeSSL)
      exclude = config.ssl_options[:redirect][:exclude]
      expect(exclude.call(request("base.tail5ece07.ts.net:3000"))).to be true
      expect(exclude.call(request("base.joenguyen.ca"))).to be false
    end

    it "keeps an exclude the app already set" do
      config.ssl_options = { redirect: { exclude: ->(r) { r.path == "/up" } } }
      described_class.install!(app)
      exclude = config.ssl_options[:redirect][:exclude]
      expect(exclude.call(request("base.joenguyen.ca", "/up"))).to be true
      expect(exclude.call(request("base.joenguyen.ca", "/jobs"))).to be false
    end

    it "does nothing without assume_ssl, and leaves redirect: false alone" do
      config.assume_ssl = false
      described_class.install!(app)
      expect(middleware).not_to have_received(:swap)
      config.assume_ssl = true
      config.ssl_options = { redirect: false }
      described_class.install!(app)
      expect(config.ssl_options[:redirect]).to be false
    end
  end
end
