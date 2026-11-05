require "openssl"
require "jwt"
require "personal_app_client/cloudflare_access"

RSpec.describe PersonalAppClient::CloudflareAccess do
  let(:rsa)    { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk)    { JWT::JWK.new(rsa, kid: "cf-key") }
  let(:issuer) { "https://jnguyen.cloudflareaccess.com" }
  let(:certs)  { "#{issuer}/cdn-cgi/access/certs" }

  def token(overrides = {}, key: jwk)
    payload = {
      "iss" => issuer,
      "sub" => "user-1",
      "email" => "joe@example.test",
      "aud" => [ "app-aud-tag" ],
      "exp" => Time.now.to_i + 300,
      "iat" => Time.now.to_i
    }.merge(overrides)
    JWT.encode(payload, key.signing_key, "RS256", { kid: key.kid })
  end

  # Stub only the network fetch: the JWKS parse, cache and JWT verification
  # all run for real.
  def stub_jwks(*bodies)
    allow(PersonalAppClient::JwksCache).to receive(:http_get_json).and_return(*bodies)
  end

  def jwks_body(*keys)
    JSON.parse(JSON.dump(keys: keys.map(&:export)))
  end

  around do |example|
    saved = ENV.to_h.slice("CF_ACCESS_TEAM_DOMAIN", "CF_ACCESS_AUD")
    ENV.delete("CF_ACCESS_TEAM_DOMAIN")
    ENV.delete("CF_ACCESS_AUD")
    PersonalAppClient::JwksCache.clear
    example.run
  ensure
    ENV.delete("CF_ACCESS_TEAM_DOMAIN")
    ENV.delete("CF_ACCESS_AUD")
    saved.each { |k, v| ENV[k] = v }
    PersonalAppClient::JwksCache.clear
  end

  before { stub_jwks(jwks_body(jwk)) }

  it "returns the claims for a valid token" do
    claims = described_class.verify(token)
    expect(claims).to include("email" => "joe@example.test", "sub" => "user-1")
  end

  it "fetches keys from the team's certs endpoint" do
    described_class.verify(token)
    expect(PersonalAppClient::JwksCache).to have_received(:http_get_json).with(certs)
  end

  it "rejects a token from another issuer" do
    expect(described_class.verify(token({ "iss" => "https://evil.cloudflareaccess.com" }))).to be_nil
  end

  it "rejects an expired token" do
    expect(described_class.verify(token({ "exp" => Time.now.to_i - 10 }))).to be_nil
  end

  it "rejects a token signed by a different key, even with the right kid" do
    forged = JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), kid: "cf-key")
    expect(described_class.verify(token({}, key: forged))).to be_nil
  end

  it "rejects a token whose kid is not in the key set" do
    other = JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), kid: "unknown")
    expect(described_class.verify(token({}, key: other))).to be_nil
  end

  it "rejects garbage, blank and nil" do
    [ "garbage", "a.b.c", "", "   ", nil ].each do |value|
      expect(described_class.verify(value)).to be_nil
    end
  end

  it "rejects an unsigned (alg none) token" do
    unsigned = JWT.encode({ "iss" => issuer, "exp" => Time.now.to_i + 300 }, nil, "none")
    expect(described_class.verify(unsigned)).to be_nil
  end

  it "rejects an HS256 token signed with the public key (algorithm confusion)" do
    confused = JWT.encode({ "iss" => issuer, "exp" => Time.now.to_i + 300 },
                          rsa.public_key.to_pem, "HS256", { kid: "cf-key" })
    expect(described_class.verify(confused)).to be_nil
  end

  it "fails closed when the keys cannot be fetched" do
    stub_jwks(nil)
    expect(described_class.verify(token)).to be_nil
  end

  describe "CF_ACCESS_AUD" do
    it "is not required when unset" do
      expect(described_class.verify(token({ "aud" => [ "anything" ] }))).not_to be_nil
    end

    it "must appear in aud when set" do
      ENV["CF_ACCESS_AUD"] = "app-aud-tag"
      expect(described_class.verify(token)).not_to be_nil
      expect(described_class.verify(token({ "aud" => [ "another-app" ] }))).to be_nil
      expect(described_class.verify(token({ "aud" => "app-aud-tag" }))).not_to be_nil
    end
  end

  describe "CF_ACCESS_TEAM_DOMAIN" do
    it "defaults to jnguyen.cloudflareaccess.com" do
      expect(described_class.issuer).to eq("https://jnguyen.cloudflareaccess.com")
    end

    it "overrides the issuer and certs URL, read at call time" do
      ENV["CF_ACCESS_TEAM_DOMAIN"] = "other.cloudflareaccess.com"
      expect(described_class.certs_url).to eq("https://other.cloudflareaccess.com/cdn-cgi/access/certs")
      expect(described_class.verify(token)).to be_nil
      expect(described_class.verify(token({ "iss" => "https://other.cloudflareaccess.com" }))).not_to be_nil
    end

    it "tolerates a scheme or trailing slash in the value" do
      ENV["CF_ACCESS_TEAM_DOMAIN"] = "https://other.cloudflareaccess.com/"
      expect(described_class.issuer).to eq("https://other.cloudflareaccess.com")
    end
  end
end
