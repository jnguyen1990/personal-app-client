require "nokogiri"

RSpec.describe "layouts/personal_app/shell" do
  let(:doc) { Nokogiri::HTML(html) }

  def with_config(**values)
    config = PersonalAppClient.config
    previous = values.keys.to_h { |key| [ key, config.instance_variable_get(:"@#{key}") ] }
    values.each { |key, value| config.public_send(:"#{key}=", value) }
    yield
  ensure
    previous.each { |key, value| config.instance_variable_set(:"@#{key}", value) }
  end

  it "renders the chrome around the page" do
    get_html "/"
    expect(last_response.status).to eq(200)
    expect(doc.at("html")["data-app"]).to eq("dummy")
    expect(doc.at("title").text).to eq("today · dummy")
    expect(doc.at(".brand-title").text).to eq("Dummy")
    expect(doc.css("h1").map(&:text)).to eq([ "today" ])
    expect(doc.at(".content #dummy-body").text).to eq("Home body")
    expect(doc.at(".sidebar-footer")).not_to be_nil
  end

  describe "the shell fixes" do
    before { get_html "/" }

    it "has a skip link to the main region" do
      link = doc.at("body > a.sr-only.skip-link")
      expect(link["href"]).to eq("#main")
      expect(doc.at("main#main.main-content")).not_to be_nil
      expect(doc.at("body").element_children.first).to eq(link)
    end

    it "labels the menu button" do
      button = doc.at("#mobileMenuBtn")
      expect(button["aria-label"]).to eq("Menu")
      expect(button["type"]).to eq("button")
      expect(button["class"]).to eq("mobile-menu-toggle")
    end

    it "leaves aria-current to shared-core (it sets it on .nav-link.active)" do
      expect(doc.css(".nav-link.active").map { |a| a["href"] }).to eq([ "/" ])
      expect(doc.css("[aria-current]")).to be_empty
    end

    it "sets theme-color per scheme, then pins it to the app's theme" do
      expect(doc.css("meta[name=theme-color]").map { |m| [ m["media"], m["content"] ] }).to eq([
        [ "(prefers-color-scheme: light)", "#f9f9fb" ], [ "(prefers-color-scheme: dark)", "#111113" ]
      ])
      pin = doc.css("head script").map(&:text).find { |t| t.include?("ds:themechange") }
      expect(pin).to include(%({"light":"#f9f9fb","dark":"#111113"}))
    end

    it "allows the safe-area insets the design system uses" do
      expect(doc.at("meta[name=viewport]")["content"]).to include("viewport-fit=cover")
    end
  end

  describe "nav" do
    it "lists the configured items with ⌘ hints" do
      get_html "/"
      links = doc.css(".nav-menu .nav-link")
      expect(links.map { |a| [ a["href"], a["data-nav-key"], a.at(".nav-ico")["data-ico"], a.at("kbd").text ] })
        .to eq([ [ "/", "1", "star", "⌘1" ], [ "/goals", "2", "target", "⌘2" ], [ "/settings", ",", "sliders", "⌘," ] ])
      expect(links.map { |a| a.xpath("text()").text.strip }).to eq(%w[today goals settings])
    end

    it "applies prefix matching" do
      get_html "/goals/7"
      expect(doc.css(".nav-link.active").map { |a| a["href"] }).to eq([ "/goals" ])
    end

    it "accepts a Proc for dynamic items" do
      with_config(nav_items: -> { [ { path: request.path, label: "here", ico: "star", key: "1" } ] }) do
        get_html "/settings"
      end
      expect(doc.css(".nav-link.active").map(&:text).map(&:strip).first).to start_with("here")
    end
  end

  describe "design system tags" do
    it "loads shared-core, the configured extras and modal-keys in order, apps-launcher deferred" do
      with_config(ds_scripts: %w[session-render goal-render]) { get_html "/" }
      scripts = doc.css("head script[src]").map { |s| [ s["src"], s.key?("defer") ] }
      expect(scripts).to eq([
        [ "https://design-system.joenguyen.ca/shared-core.js", false ],
        [ "https://design-system.joenguyen.ca/session-render.js", false ],
        [ "https://design-system.joenguyen.ca/goal-render.js", false ],
        [ "https://design-system.joenguyen.ca/modal-keys.js", false ],
        [ "https://design-system.joenguyen.ca/apps-launcher.js", true ]
      ])
      expect(doc.css("head link[rel=stylesheet]").first["href"]).to eq("https://design-system.joenguyen.ca/design-system.css")
      preload = doc.at("head link[rel=preload]")
      expect(preload.to_h).to include("href" => "https://design-system.joenguyen.ca/fonts/inter-latin-wght.woff2",
                                      "as" => "font", "type" => "font/woff2", "crossorigin" => "")
    end

    it "honours DS_BASE" do
      ENV["DS_BASE"] = "http://localhost:8804"
      get_html "/"
      expect(doc.css("head link[rel=stylesheet]").first["href"]).to eq("http://localhost:8804/design-system.css")
    ensure
      ENV.delete("DS_BASE")
    end

    context "with a public/ds snapshot" do
      let(:snapshot) { Rails.root.join("public", "ds") }

      before do
        FileUtils.mkdir_p(snapshot)
        File.write(snapshot.join("design-system.css"), "/* snapshot */")
        PersonalAppClient::ShellHelper.reset_snapshot_cache!
      end

      after do
        FileUtils.rm_rf(snapshot)
        PersonalAppClient::ShellHelper.reset_snapshot_cache!
      end

      it "falls back to the local copy when the CDN fails" do
        get_html "/"
        css = doc.css("head link[rel=stylesheet]").first
        expect(css["onerror"]).to eq("this.onerror=null;this.href='/ds/design-system.css'")
        check = doc.css("head script:not([src])").map(&:text).find { |t| t.include?("installNavHotkeys||") }
        expect(check).to include(%(<script src="/ds/shared-core.js"><\\/script>), %(<script src="/ds/modal-keys.js"><\\/script>))
        launcher = doc.at("head script[src$='apps-launcher.js']")
        expect(launcher["onerror"]).to include("/ds/apps-launcher.js")
      end

      it "can be switched off" do
        with_config(ds_fallback: false) { get_html "/" }
        expect(doc.css("head link[rel=stylesheet]").first["onerror"]).to be_nil
      end
    end

    it "emits no fallback without a snapshot" do
      get_html "/"
      expect(html).not_to include("/ds/")
    end
  end

  describe "header" do
    it "puts title, badge and actions on one row with the subtitle under it (inline)" do
      get_html "/"
      header = doc.at("header.page-header")
      row = header.element_children.first
      expect(row["class"]).to eq("d-flex align-center gap-3")
      expect(row.element_children.map(&:name)).to eq(%w[h1 div])
      expect(header.at("> p.page-subtitle").text).to eq("monday · 23 nov")
    end

    it "stacks title over subtitle with actions to the right (split, base)" do
      with_config(header_style: :split) { get_html "/" }
      outer = doc.at("header.page-header > div")
      left, right = outer.element_children
      expect(left.at("> div.d-flex > h1").text).to eq("today")
      expect(left.at("> p.page-subtitle")).not_to be_nil
      expect(right["class"]).to eq("header-actions")
    end

    it "renders the subtitle as a span when configured (upkeep)" do
      with_config(subtitle_tag: :span) { get_html "/" }
      expect(doc.at("header > span.page-subtitle")).not_to be_nil
    end

    it "defaults the h1 to the app id" do
      get_html "/settings"
      expect(doc.at("h1").text).to eq("settings")
      expect(doc.at("title").text).to eq("settings · dummy")
    end
  end

  describe "slots" do
    it "puts :head at the end of head and :extra_js after the hotkeys script" do
      get_html "/"
      expect(doc.at("head").element_children.last["name"]).to eq("dummy-head")
      body_scripts = doc.css("body > script").map(&:text)
      expect(body_scripts.first).to include("installNavHotkeys({ allowComma: true })")
      expect(body_scripts.last).to include("window.dummyExtra")
    end

    it "can leave hotkeys to the app" do
      with_config(nav_hotkeys: false) { get_html "/" }
      expect(html).not_to include("installNavHotkeys({")
    end

    it "renders flash between the header and the content" do
      get_html "/flash-demo"
      flashes = doc.css("main > .status-message")
      expect(flashes.map { |f| [ f["class"], f.text ] }).to eq([
        [ "status-message status-success", "Saved" ], [ "status-message status-error", "Careful" ]
      ])
      expect(doc.at("main").element_children.map(&:name)).to eq(%w[header div div div])
    end
  end

  describe "an app overriding a shell partial" do
    around do |example|
      dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(dir, "personal_app"))
      File.write(File.join(dir, "personal_app", "_flash.html.erb"), %(<div id="app-flash">mine</div>))
      ActionController::Base.prepend_view_path(dir)
      example.run
    ensure
      ActionController::Base.view_paths = ActionController::Base.view_paths.to_a.reject { |p| p.to_s == dir }
      FileUtils.rm_rf(dir)
    end

    it "uses the app's file" do
      get_html "/"
      expect(doc.at("#app-flash").text).to eq("mine")
    end
  end

  describe "PWA and error hook tags" do
    it "links the manifest with credentials and registers the worker" do
      get_html "/"
      expect(doc.at("link[rel=manifest]").to_h).to include("href" => "/manifest.json", "crossorigin" => "use-credentials")
      expect(html).to include("navigator.serviceWorker.register('/service-worker.js')")
    end

    it "unregisters instead when the kill switch is set" do
      PersonalAppClient.config.pwa.service_worker = :unregister
      get_html "/"
      expect(html).to include("getRegistrations()")
      expect(html).not_to include(".register(")
    ensure
      PersonalAppClient.config.pwa.service_worker = true
    end
  end
end
