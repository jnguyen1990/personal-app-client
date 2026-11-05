require "personal_app_client/rails/operator_auth"

class FakeOperatorController < FakeActionController
  include PersonalAppClient::Rails::OperatorAuth
  operator_auth enforce: true

  def wipe_data = render(json: { success: true })
  def index     = render(json: { settings: [] })
end

class FakeScopedOperatorController < FakeActionController
  include PersonalAppClient::Rails::OperatorAuth
  operator_auth only: [ :wipe_data ], enforce: true

  def wipe_data = render(json: { success: true })
  def index     = render(json: { settings: [] })
end

class FakeDefaultOperatorController < FakeActionController
  include PersonalAppClient::Rails::OperatorAuth

  def wipe_data = render(json: { success: true })
end

RSpec.describe PersonalAppClient::Rails::OperatorAuth do
  let(:secret) { "s3cret-inter-app" }
  let(:unauthorized) { { json: { error: "unauthorized" }, status: :unauthorized } }
  let(:ok) { { json: { success: true } } }

  around do |example|
    saved = ENV.to_h.slice("INTER_APP_SECRET", "OPERATOR_AUTH_ENFORCE")
    ENV["INTER_APP_SECRET"] = secret
    ENV.delete("OPERATOR_AUTH_ENFORCE")
    example.run
  ensure
    ENV.delete("INTER_APP_SECRET")
    ENV.delete("OPERATOR_AUTH_ENFORCE")
    saved.each { |k, v| ENV[k] = v }
  end

  # No Access token verifies unless an example says so.
  before { allow(PersonalAppClient::CloudflareAccess).to receive(:verify).and_return(nil) }

  def run(klass = FakeOperatorController, action = :wipe_data, **request)
    klass.new(**request).process(action)
  end

  it "registers the before_action" do
    expect(FakeOperatorController.before_actions).to include(:authenticate_operator!)
  end

  it "rejects a request with no credentials" do
    expect(run.rendered).to eq(unauthorized)
  end

  describe "X-App-Auth" do
    it "passes when it matches INTER_APP_SECRET" do
      c = run(headers: { "X-App-Auth" => secret })
      expect(c.rendered).to eq(ok)
      expect(c.current_operator).to eq(:inter_app)
    end

    it "rejects a wrong secret" do
      expect(run(headers: { "X-App-Auth" => "wrong" }).rendered).to eq(unauthorized)
      expect(run(headers: { "X-App-Auth" => "#{secret}x" }).rendered).to eq(unauthorized)
    end

    it "compares in constant time" do
      expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).with(secret, secret).and_call_original
      run(headers: { "X-App-Auth" => secret })
    end

    it "never passes when the server has no secret configured" do
      ENV.delete("INTER_APP_SECRET")
      expect(run(headers: { "X-App-Auth" => "" }).rendered).to eq(unauthorized)
      expect(run(headers: { "X-App-Auth" => "anything" }).rendered).to eq(unauthorized)
    end
  end

  describe "Cloudflare Access" do
    it "passes with a token CloudflareAccess verifies, exposing the identity" do
      allow(PersonalAppClient::CloudflareAccess).to receive(:verify)
        .with("good.jwt").and_return("email" => "joe@example.test", "sub" => "u1")
      c = run(headers: { "Cf-Access-Jwt-Assertion" => "good.jwt" })
      expect(c.rendered).to eq(ok)
      expect(c.current_operator).to eq("joe@example.test")
    end

    it "falls back to the CF_Authorization cookie (Access bypass paths)" do
      allow(PersonalAppClient::CloudflareAccess).to receive(:verify)
        .with("cookie.jwt").and_return("sub" => "u1")
      c = run(cookies: { "CF_Authorization" => "cookie.jwt" })
      expect(c.rendered).to eq(ok)
      expect(c.current_operator).to eq("u1")
    end

    it "rejects a token that does not verify" do
      expect(run(headers: { "Cf-Access-Jwt-Assertion" => "bad.jwt" }).rendered).to eq(unauthorized)
      expect(PersonalAppClient::CloudflareAccess).to have_received(:verify).with("bad.jwt")
    end

    it "does not trust Cf-Access-Authenticated-User-Email on its own" do
      c = run(headers: { "Cf-Access-Authenticated-User-Email" => "joe@example.test" })
      expect(c.rendered).to eq(unauthorized)
    end

    it "verifies a real token end to end" do
      allow(PersonalAppClient::CloudflareAccess).to receive(:verify).and_call_original
      PersonalAppClient::JwksCache.clear
      jwk = JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), kid: "cf")
      allow(PersonalAppClient::JwksCache).to receive(:http_get_json)
        .and_return(JSON.parse(JSON.dump(keys: [ jwk.export ])))
      claims = { "iss" => PersonalAppClient::CloudflareAccess.issuer, "email" => "joe@example.test",
                 "exp" => Time.now.to_i + 60 }
      good = JWT.encode(claims, jwk.signing_key, "RS256", { kid: "cf" })
      stale = JWT.encode(claims.merge("exp" => Time.now.to_i - 60), jwk.signing_key, "RS256", { kid: "cf" })

      expect(run(headers: { "Cf-Access-Jwt-Assertion" => good }).rendered).to eq(ok)
      expect(run(headers: { "Cf-Access-Jwt-Assertion" => stale }).rendered).to eq(unauthorized)
    ensure
      PersonalAppClient::JwksCache.clear
    end
  end

  describe "enforcement" do
    it "is off outside production by default" do
      expect(run(FakeDefaultOperatorController).rendered).to eq(ok)
    end

    it "is on in production by default" do
      with_rails_env("production") do
        expect(run(FakeDefaultOperatorController).rendered).to eq(unauthorized)
        expect(run(FakeDefaultOperatorController, headers: { "X-App-Auth" => secret }).rendered).to eq(ok)
      end
    end

    it "can be forced on with OPERATOR_AUTH_ENFORCE" do
      ENV["OPERATOR_AUTH_ENFORCE"] = "1"
      expect(run(FakeDefaultOperatorController).rendered).to eq(unauthorized)
    end

    it "cannot be switched off in production through the ENV" do
      ENV["OPERATOR_AUTH_ENFORCE"] = "0"
      with_rails_env("production") do
        expect(run(FakeDefaultOperatorController).rendered).to eq(unauthorized)
      end
    end

    it "honours a class-level override, inherited by subclasses" do
      off = Class.new(FakeOperatorController) { operator_auth enforce: false }
      expect(run(Class.new(FakeOperatorController)).rendered).to eq(unauthorized)
      with_rails_env("production") { expect(run(off).rendered).to eq(ok) }
      expect(run(FakeOperatorController).rendered).to eq(unauthorized) # parent untouched
    end
  end

  describe "operator_auth only:" do
    it "guards only the listed actions" do
      expect(run(FakeScopedOperatorController, :index).rendered).to eq(json: { settings: [] })
      expect(run(FakeScopedOperatorController, :wipe_data).rendered).to eq(unauthorized)
      expect(run(FakeScopedOperatorController, :wipe_data, headers: { "X-App-Auth" => secret }).rendered).to eq(ok)
    end

    it "registers the callback once" do
      expect(FakeScopedOperatorController.before_actions.count(:authenticate_operator!)).to eq(1)
    end
  end
end
