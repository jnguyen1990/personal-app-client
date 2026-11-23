require "tmpdir"
require "personal_app_client/ds_snapshot"

RSpec.describe PersonalAppClient::DsSnapshot do
  let(:dir) { Dir.mktmpdir }
  let(:dest) { File.join(dir, "public", "ds") }
  after { FileUtils.rm_rf(dir) }

  let(:files) do
    {
      "design-system.css" => %(@import url("https://fonts.googleapis.com/x"); @font-face { src: url("fonts/Inter.woff2?v=2") }
                               .a { background: url(data:image/svg+xml,abc) } .b { background: url('../img/x.svg') }),
      "shared-core.js" => "/* core */",
      "fonts/Inter.woff2" => "WOFF",
      "img/x.svg" => "<svg/>"
    }
  end

  let(:fetched) { [] }
  let(:fetcher) do
    lambda do |uri|
      fetched << uri.to_s
      files.fetch(uri.path.delete_prefix("/")) { raise PersonalAppClient::Error, "404 #{uri}" }
    end
  end

  it "copies the files and the stylesheet's relative url() targets" do
    written = described_class.run!(dest: dest, base: "https://ds.test", files: %w[design-system.css shared-core.js],
                                   fetcher: fetcher)
    expect(written).to eq(%w[design-system.css shared-core.js fonts/Inter.woff2 img/x.svg])
    expect(File.read(File.join(dest, "fonts", "Inter.woff2"))).to eq("WOFF")
    expect(fetched).to include("https://ds.test/fonts/Inter.woff2")
    expect(fetched.grep(/googleapis|data:/)).to be_empty
  end

  it "keeps the previous snapshot when a file is missing" do
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, "design-system.css"), "old")
    expect do
      described_class.run!(dest: dest, base: "https://ds.test", files: %w[design-system.css nope.js], fetcher: fetcher)
    end.to raise_error(PersonalAppClient::Error, /nope/)
    expect(File.read(File.join(dest, "design-system.css"))).to eq("old")
    expect(Dir.glob("#{dest}.tmp-*")).to be_empty
  end
end
