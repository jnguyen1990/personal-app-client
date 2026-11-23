require "nokogiri"

RSpec.describe "settings pane partials" do
  let(:doc) { Nokogiri::HTML(html) }

  before { get_html "/settings" }

  describe "connector pane" do
    let(:pane) { doc.at("section.pane[data-pane=connector]") }

    it "renders the endpoint, auth and the registry's tools" do
      expect(pane["hidden"]).not_to be_nil
      expect(pane.at(".card-subtitle").text).to eq("Lets Claude poke the dummy.")
      expect(pane.at(".badge").text).to eq("3 tools")
      expect(pane.at("#mcp-url").text).to eq("http://example.org/api/mcp")
      expect(pane.at("button[data-copy-target='#mcp-url']")).not_to be_nil
      expect(pane.css("dd").last.text).to eq("OAuth 2.1 · base authorization server")
      tools = pane.css(".tool-item").map { |t| [ t.at("code").text, t.at("span").text ] }
      expect(tools.first).to eq([ "echo", "Echo the arguments back." ])
      expect(tools.map(&:first)).to eq(%w[echo crash picky])
    end
  end

  describe "about pane" do
    let(:pane) { doc.at("section.pane[data-pane=about]") }

    it "lists lead facts, Rails, Host, facts, Connector and Design system in order" do
      rows = pane.css("dt").map(&:text).zip(pane.css("dd").map(&:text))
      expect(rows.map(&:first)).to eq([ "Version", "Rails", "Host", "Notes", "Connector", "Design system" ])
      expect(rows.to_h).to include("Version" => "1.2.3", "Host" => "example.org", "Notes" => "7 kept",
                                   "Connector" => "3 tools over MCP", "Design system" => "design-system.joenguyen.ca")
      expect(rows.to_h["Rails"]).to eq("#{Rails.version} · ruby #{RUBY_VERSION}")
    end
  end

  describe "backup pane" do
    let(:pane) { doc.at("section.pane[data-pane=data]") }

    it "renders the full backup UI with its own restore modal and script" do
      expect(pane.at(".card-title").text).to eq("Backup and restore")
      expect(pane.css(".card-header button").map(&:text)).to eq([ "Upload ZIP", "Create backup" ])
      expect(pane.at("input[type=file][accept='.zip'][hidden]")).not_to be_nil
      expect(doc.at("#pa-restore-modal .btn-danger[disabled]").text).to eq("Restore database")
      script = pane.at("script").text
      expect(script).to include("/api/backup/list", "/api/backup/create", "/api/backup/restore-upload",
                                "settingspane:change", "document.body.appendChild(modal)")
    end
  end

  describe "rendering with other locals" do
    def render_partial(name, **locals)
      ApplicationController.render(partial: "personal_app/settings/#{name}", locals: locals)
    end

    it "offers the one-link backup pane" do
      out = Nokogiri::HTML(render_partial("backup_pane", mode: :link, title: "Backup", subtitle: "A full database zip."))
      expect(out.at("a.btn-primary")["href"]).to eq("/api/backup/create")
      expect(out.at("script")).to be_nil
    end

    it "takes tool classes or descriptor hashes, an open pane and no connector line" do
      out = Nokogiri::HTML(render_partial("connector_pane", tools: [ { name: "x", description: "Does x. More." } ],
                                                             hidden: false, mcp_url: "https://dummy.joenguyen.ca/api/mcp"))
      expect(out.at("section")["hidden"]).to be_nil
      expect(out.at(".tool-item").text.squish).to eq("x Does x.")
      expect(out.at("#mcp-url").text).to eq("https://dummy.joenguyen.ca/api/mcp")

      about = Nokogiri::HTML(render_partial("about_pane", connector: false))
      expect(about.css("dt").map(&:text)).to eq([ "Rails", "Host", "Design system" ])
    end
  end
end
