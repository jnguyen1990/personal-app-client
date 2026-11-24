RSpec.describe PersonalAppClient::RequestLog do
  let(:io) { StringIO.new }

  before { described_class.install!(logger: Logger.new(io)) }
  after { described_class.uninstall! }

  it "logs one key=value line per request" do
    get_html "/?secret=1"
    line = io.string.lines.grep(/\Arequest |request method=/).last
    expect(line).to match(%r{request method=GET path=/ status=200 duration_ms=[\d.]+ })
    expect(line).not_to include("secret")
    expect(line).to include("controller=")
  end
end
