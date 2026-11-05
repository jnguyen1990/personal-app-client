require "openssl"
require "jwt"
require "personal_app_client/jwks_cache"

RSpec.describe PersonalAppClient::JwksCache do
  let(:url)  { "https://issuer.example.test/keys" }
  let(:jwk)  { JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), kid: "k1") }
  let(:body) { JSON.parse(JSON.dump(keys: [ jwk.export ])) }

  before { described_class.clear }
  after  { described_class.clear }

  def stub_fetch(*results)
    allow(described_class).to receive(:http_get_json).and_return(*results)
  end

  it "returns nil for a blank URL without fetching" do
    expect(described_class).not_to receive(:http_get_json)
    expect(described_class.fetch(nil)).to be_nil
    expect(described_class.fetch("")).to be_nil
  end

  it "fetches the key set and caches it per URL" do
    stub_fetch(body)
    set = described_class.fetch(url)
    expect(set).to be_a(JWT::JWK::Set)
    expect(set.keys.map(&:kid)).to eq([ "k1" ])

    expect(described_class.fetch(url)).to equal(set)
    expect(described_class).to have_received(:http_get_json).once
  end

  it "keeps separate entries for separate URLs" do
    stub_fetch(body)
    described_class.fetch(url)
    described_class.fetch("https://other.example.test/keys")
    expect(described_class).to have_received(:http_get_json).twice
  end

  it "refetches once the TTL has passed" do
    stub_fetch(body)
    now = 0
    allow(described_class).to receive(:monotonic) { now }
    described_class.fetch(url)
    now = described_class::TTL + 1
    described_class.fetch(url)
    expect(described_class).to have_received(:http_get_json).twice
  end

  it "reuses stale keys when the refresh fails (network blip)" do
    stub_fetch(body, nil)
    now = 0
    allow(described_class).to receive(:monotonic) { now }
    first = described_class.fetch(url)
    now = described_class::TTL + 1
    expect(described_class.fetch(url)).to equal(first)
  end

  it "returns nil when the first fetch fails" do
    stub_fetch(nil)
    expect(described_class.fetch(url)).to be_nil
  end

  it "returns nil rather than raising on a malformed key set" do
    stub_fetch({ "keys" => [ { "kty" => "nonsense" } ] })
    expect(described_class.fetch(url)).to be_nil
  end

  it "swallows network errors in the HTTP fetch" do
    allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo")
    expect(described_class.fetch(url)).to be_nil
  end
end
