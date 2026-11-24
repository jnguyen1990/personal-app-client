# PLAT-18: GET /api/search — this app's results for the command palette.
RSpec.describe "command-palette search" do
  let(:config) { PersonalAppClient.config }

  around do |example|
    previous = config.search
    config.search = lambda do |q, limit:|
      [
        { kind: "Note", title: "Costco run #{q}", meta: "Sat Nov 29", url: "/notes/1",
          preview: { heading: "Costco run", amount: "−$12.00", amount_tone: "negative", fields: [ [ "List", "weekly" ] ],
                     actions: [ { label: "Open", url: "/notes/1" }, { label: "", url: "/x" } ] } },
        { kind: "Note", title: "" } # dropped: no title
      ].first(limit)
    end
    example.run
  ensure
    config.search = previous
  end

  describe "GET /api/search" do
    it "answers this app's results in the documented shape" do
      get "/api/search", { q: "costco" }
      expect(last_response.status).to eq(200)
      expect(json["app"]).to eq("dummy")
      r = json["results"].sole
      expect(r).to include("kind" => "Note", "title" => "Costco run costco", "meta" => "Sat Nov 29", "url" => "/notes/1")
      expect(r["preview"]).to eq(
        "heading" => "Costco run", "amount" => "−$12.00", "amount_tone" => "negative",
        "fields" => [ [ "List", "weekly" ] ], "actions" => [ { "label" => "Open", "url" => "/notes/1" } ]
      )
    end

    it "refuses a query under two characters" do
      get "/api/search", { q: " c " }
      expect(last_response.status).to eq(422)
    end

    it "answers no results when the app has no search, or its search raises" do
      config.search = nil
      get "/api/search", { q: "costco" }
      expect(json["results"]).to eq([])
      config.search = ->(*, **) { raise "boom" }
      get "/api/search", { q: "costco" }
      expect(last_response.status).to eq(200)
      expect(json["results"]).to eq([])
    end
  end
end
