require "nokogiri"

# PLAT-22: settings and single-form pages get .content-narrow (~720px).
RSpec.describe "narrow content pages" do
  let(:config) { PersonalAppClient.config }
  # Methods, not lets: several requests per example.
  def content_class = Nokogiri::HTML(html).at("main > div.content")["class"]

  it "leaves ordinary pages full width" do
    get_html "/"
    expect(content_class).to eq("content")
  end

  it "narrows settings and new/edit forms by default" do
    get_html "/settings"
    expect(content_class).to eq("content content-narrow")
    get_html "/goals/new"
    expect(content_class).to eq("content content-narrow")
  end

  it "lets a page opt out with content_for :content_width, \"wide\"" do
    get_html "/forms/new"
    expect(content_class).to eq("content")
  end

  it "follows config.narrow_pages (Regexp, exact String or Proc)" do
    previous = config.narrow_pages
    config.narrow_pages = [ "/goals", ->(req) { req.path.start_with?("/goals/") } ]
    get_html "/goals"
    expect(content_class).to eq("content content-narrow")
    get_html "/goals/3"
    expect(content_class).to eq("content content-narrow")
    get_html "/settings"
    expect(content_class).to eq("content")
  ensure
    config.narrow_pages = previous
  end
end
