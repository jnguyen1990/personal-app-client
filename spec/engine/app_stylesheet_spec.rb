require "nokogiri"

# PLAT-27: design-system.css, then this app's own apps/<app_id>.css.
RSpec.describe "the app's own stylesheet" do
  let(:config) { PersonalAppClient.config }
  let(:doc) { Nokogiri::HTML(html) }

  it "links apps/<app_id>.css right after design-system.css, from the pinned release when it has the file" do
    release = { "sha" => "abc123def456", "files" => { "design-system.css" => "sha384-A", "apps/dummy.css" => "sha384-B" } }
    previous = config.instance_variable_get(:@ds_release)
    config.ds_release = release
    get_html "/"
    links = doc.css("head link[rel=stylesheet]").first(2)
    expect(links.map { |l| l["href"] }).to eq([ "https://design-system.joenguyen.ca/v/abc123def456/design-system.css",
                                               "https://design-system.joenguyen.ca/v/abc123def456/apps/dummy.css" ])
    expect(links.map { |l| l["integrity"] }).to eq(%w[sha384-A sha384-B])
  ensure
    config.instance_variable_set(:@ds_release, previous)
  end

  it "can be switched off" do
    config.app_stylesheet = false
    get_html "/"
    expect(doc.css("head link[rel=stylesheet]").map { |l| l["href"] }.grep(/apps\//)).to be_empty
  ensure
    config.app_stylesheet = true
  end

  it "is part of the offline snapshot" do
    expect(config.ds_snapshot_files).to include("design-system.css", "apps/dummy.css")
  end
end
