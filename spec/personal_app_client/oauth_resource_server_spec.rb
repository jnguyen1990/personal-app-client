require "ostruct"
require "openssl"
require "jwt"
require "personal_app_client/rails/oauth_resource_server"

# Minimal Rails stand-in (matches api_key_auth_spec style).
module Rails
  def self.application
    @application ||= OpenStruct.new(credentials: {})
  end
end

class FakeResponse
  attr_reader :headers
  def initialize
    @headers = {}
  end

  def set_header(k, v)
    @headers[k] = v
  end
end

class FakeOauthController
  def self.before_actions
    @before_actions ||= []
  end

  def self.before_action(method_name)
    before_actions << method_name
  end

  class << self
    attr_accessor :oauth_rs_issuer_env, :oauth_rs_jwks_env,
                  :oauth_rs_resource_env, :oauth_rs_metadata_env,
                  :oauth_rs_shared_key_env
  end

  attr_writer :request
  attr_reader :rendered, :response

  def initialize
    @response = FakeResponse.new
  end

  def request
    @request ||= OpenStruct.new(headers: {})
  end

  def render(payload)
    @rendered = payload
  end

  include PersonalAppClient::Rails::OauthResourceServer
end

RSpec.describe PersonalAppClient::Rails::OauthResourceServer do
  let(:rsa)    { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk)    { JWT::JWK.new(rsa, kid: "test-key") }
  let(:jwks)   { JWT::JWK::Set.new(keys: [ jwk.export ]) }
  # What an unauthorized render looks like through the fake controller.
  let(:unauth) { { json: { error: "unauthorized" }, status: :unauthorized } }
  let(:issuer)   { "https://base.example.test" }
  let(:resource) { "https://app.example.test/api/mcp" }
  let(:metadata) { "https://app.example.test/.well-known/oauth-protected-resource" }

  def build_token(overrides = {})
    payload = {
      "iss" => issuer,
      "sub" => "joe@rotessa.com",
      "aud" => resource,
      "exp" => Time.now.to_i + 300,
      "iat" => Time.now.to_i
    }.merge(overrides)
    JWT.encode(payload, jwk.signing_key, "RS256", { kid: jwk.kid })
  end

  def controller_with(auth_header: nil, api_key: nil)
    c = FakeOauthController.new
    headers = {}
    headers["Authorization"] = auth_header if auth_header
    headers["X-API-Key"] = api_key if api_key
    c.request = OpenStruct.new(headers: headers)
    # Stub the network fetch so unit tests stay offline.
    allow(c).to receive(:jwks_keys).and_return(jwks)
    c
  end

  around do |example|
    ENV["MCP_OAUTH_ISSUER"]   = issuer
    ENV["MCP_OAUTH_JWKS_URL"] = "https://base.example.test/oauth/discovery/keys"
    ENV["MCP_RESOURCE_URL"]   = resource
    ENV["MCP_PR_METADATA_URL"] = metadata
    ENV.delete("MCP_API_KEY")
    example.run
  ensure
    %w[MCP_OAUTH_ISSUER MCP_OAUTH_JWKS_URL MCP_RESOURCE_URL MCP_PR_METADATA_URL MCP_API_KEY]
      .each { |k| ENV.delete(k) }
    FakeOauthController.instance_variable_set(:@oauth_rs_jwks_cache, nil)
  end

  it "registers the before_action" do
    expect(FakeOauthController.before_actions).to include(:authenticate_mcp!)
  end

  it "accepts a valid bearer JWT and exposes the subject" do
    c = controller_with(auth_header: "Bearer #{build_token}")
    c.send(:authenticate_mcp!)
    expect(c.rendered).to be_nil
    expect(c.current_mcp_subject).to eq("joe@rotessa.com")
  end

  it "rejects a token whose audience does not match this resource" do
    c = controller_with(auth_header: "Bearer #{build_token('aud' => 'https://other.app/api/mcp')}")
    c.send(:authenticate_mcp!)
    expect(c.rendered).to eq(unauth)
  end

  it "accepts a token that carries the resource via RFC 8707 `resource`" do
    token = build_token("aud" => "https://other/api/mcp", "resource" => resource)
    c = controller_with(auth_header: "Bearer #{token}")
    c.send(:authenticate_mcp!)
    expect(c.current_mcp_subject).to eq("joe@rotessa.com")
  end

  it "rejects an expired token" do
    c = controller_with(auth_header: "Bearer #{build_token('exp' => Time.now.to_i - 10)}")
    c.send(:authenticate_mcp!)
    expect(c.rendered).to eq(unauth)
  end

  it "rejects a token signed by a different key" do
    other = JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), kid: "test-key")
    forged = JWT.encode({ "iss" => issuer, "sub" => "x", "aud" => resource,
                          "exp" => Time.now.to_i + 300 }, other.signing_key, "RS256",
                        { kid: "test-key" })
    c = controller_with(auth_header: "Bearer #{forged}")
    c.send(:authenticate_mcp!)
    expect(c.rendered).to eq(unauth)
  end

  it "rejects a wrong issuer" do
    c = controller_with(auth_header: "Bearer #{build_token('iss' => 'https://evil')}")
    c.send(:authenticate_mcp!)
    expect(c.rendered).to eq(unauth)
  end

  it "sets a WWW-Authenticate resource_metadata header on failure" do
    c = controller_with(auth_header: "Bearer not-a-jwt")
    c.send(:authenticate_mcp!)
    expect(c.response.headers["WWW-Authenticate"])
      .to eq(%(Bearer resource_metadata="#{metadata}"))
  end

  context "legacy shared-key fallback" do
    it "accepts the shared key via X-API-Key when MCP_API_KEY is set" do
      ENV["MCP_API_KEY"] = "s3cr3t-shared-key-value"
      c = controller_with(api_key: "s3cr3t-shared-key-value")
      c.send(:authenticate_mcp!)
      expect(c.rendered).to be_nil
      expect(c.current_mcp_subject).to eq(:shared_key)
    end

    it "accepts the shared key via Authorization: Bearer <shared>" do
      ENV["MCP_API_KEY"] = "s3cr3t-shared-key-value"
      c = controller_with(auth_header: "Bearer s3cr3t-shared-key-value")
      c.send(:authenticate_mcp!)
      expect(c.current_mcp_subject).to eq(:shared_key)
    end

    it "rejects a wrong shared key" do
      ENV["MCP_API_KEY"] = "s3cr3t-shared-key-value"
      c = controller_with(api_key: "wrong")
      c.send(:authenticate_mcp!)
      expect(c.rendered).to eq(unauth)
    end

    it "does not fall back when MCP_API_KEY is unset" do
      c = controller_with(api_key: "anything")
      c.send(:authenticate_mcp!)
      expect(c.rendered).to eq(unauth)
    end
  end
end
