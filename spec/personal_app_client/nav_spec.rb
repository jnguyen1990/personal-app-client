require "personal_app_client/nav"

RSpec.describe PersonalAppClient::Nav do
  def active(spec, path)
    described_class.item(spec, path).active?
  end

  it "matches the exact path by default" do
    expect(active({ path: "/due" }, "/due")).to be(true)
    expect(active({ path: "/due" }, "/due/3")).to be(false)
    expect(active({ path: "/" }, "/settings")).to be(false)
  end

  it "matches a prefix" do
    expect(active({ path: "/goals", active: :prefix }, "/goals/7")).to be(true)
    expect(active({ path: "/goals", active: :prefix }, "/archive")).to be(false)
  end

  it "adds extra prefixes (upkeep's garage, mealplanner's today)" do
    garage = { path: "/", prefixes: %w[/items] }
    expect(active(garage, "/")).to be(true)
    expect(active(garage, "/items/4")).to be(true)
    expect(active(garage, "/due")).to be(false)
  end

  it "takes a Regexp, a Proc or a boolean" do
    expect(active({ path: "/x", active: %r{\A/x(/|\z)} }, "/x/1")).to be(true)
    expect(active({ path: "/x", active: ->(p) { p.end_with?("!") } }, "/y!")).to be(true)
    expect(active({ path: "/x", active: -> { true } }, "/nope")).to be(true)
    expect(active({ path: "/x", active: false }, "/x")).to be(false)
  end

  it "rejects an unknown rule" do
    expect { active({ path: "/x", active: :fuzzy }, "/x") }.to raise_error(ArgumentError, /active must be/)
  end

  it "builds items with ⌘ hints, string or symbol keys" do
    items = described_class.items([ { "path" => "/", "label" => "today", "ico" => "star", "key" => 1 },
                                    { path: "/s", label: "settings", ico: "sliders", key: "," },
                                    { path: "/n", label: "no key", ico: "x" } ], "/")
    expect(items.map { |i| [ i.label, i.kbd, i.active? ] }).to eq([ [ "today", "⌘1", true ], [ "settings", "⌘,", false ],
                                                                   [ "no key", nil, false ] ])
  end
end
