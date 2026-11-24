require "nokogiri"

# PLAT-17: the shell turns on the design system's ⌘K palette.
RSpec.describe "command palette in the shell" do
  let(:config) { PersonalAppClient.config }
  let(:doc) { Nokogiri::HTML(html) }

  def with(**values)
    previous = values.keys.to_h { |k| [ k, config.public_send(k) ] }
    values.each { |k, v| config.public_send(:"#{k}=", v) }
    yield
  ensure
    previous.each { |k, v| config.public_send(:"#{k}=", v) }
  end

  it "points the palette at this app's search when config.search is set" do
    with(search: ->(_q, limit:) { [] }) { get_html "/" }
    expect(doc.at('meta[name="ds-palette"]')["content"]).to eq("/api/search")
  end

  it "still turns the palette on (pages and actions only) without a search" do
    with(search: nil) { get_html "/" }
    expect(doc.at('meta[name="ds-palette"]')["content"]).to eq("")
  end

  it "renders the open control in the sidebar and the phone More sheet" do
    get_html "/"
    trigger = doc.at(".sidebar-header button.palette-trigger[data-palette-open]")
    expect(trigger.text).to include("Search")
    expect(trigger["aria-keyshortcuts"]).to eq("Meta+K")
    expect(doc.at("#more-sheet [data-palette-open]")).not_to be_nil if doc.at("#more-sheet")
  end

  it "renders nothing when switched off" do
    with(palette: false) { get_html "/" }
    expect(doc.at('meta[name="ds-palette"]')).to be_nil
    expect(doc.at("[data-palette-open]")).to be_nil
  end
end
