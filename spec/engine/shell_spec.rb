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

    it "leaves the sidebar's aria-current to shared-core (it sets it on .nav-link.active)" do
      expect(doc.css(".sidebar .nav-link.active").map { |a| a["href"] }).to eq([ "/" ])
      expect(doc.css(".sidebar [aria-current]")).to be_empty
    end

    it "sets theme-color per scheme, then pins it to the app's theme" do
      expect(doc.css("meta[name=theme-color]").map { |m| [ m["media"], m["content"] ] }).to eq([
        [ "(prefers-color-scheme: light)", "#ffffff" ], [ "(prefers-color-scheme: dark)", "#111113" ]
      ])
      pin = doc.css("head script").map(&:text).find { |t| t.include?("ds:themechange") }
      expect(pin).to include(%({"light":"#ffffff","dark":"#111113"}))
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

  describe "mobile tab bar" do
    let(:five) do
      [ { path: "/",         label: "today",    ico: "star",     key: "1" },
        { path: "/goals",    label: "goals",    ico: "target",   key: "2", active: :prefix },
        { path: "/plan",     label: "plan",     ico: "calendar", key: "3" },
        { path: "/archive",  label: "archive",  ico: "archive",  key: "4" },
        { path: "/settings", label: "settings", ico: "sliders",  key: "," } ]
    end

    def tabs = doc.css("body > nav.tab-bar > a.tab-bar-item")
    def sheet_links = doc.css("#more-sheet .nav-menu .nav-link").map { |a| a["href"] }

    it "renders the first four items as tabs plus More, after main, with the rest in the sheet" do
      with_config(nav_items: five) { get_html "/goals/3" }
      expect(tabs.map { |a| a["href"] }).to eq(%w[/ /goals /plan /archive])
      expect(tabs.map { |a| a.at(".tab-bar-label").text }).to eq(%w[today goals plan archive])
      expect(tabs.map { |a| a.at(".nav-ico")["data-ico"] }).to eq(%w[star target calendar archive])
      active = doc.css(".tab-bar-item.active")
      expect(active.map { |a| [ a["href"], a["aria-current"] ] }).to eq([ [ "/goals", "page" ] ])
      expect(doc.at("main").next_element["class"]).to eq("tab-bar")
      expect(sheet_links).to eq(%w[/settings])
    end

    it "wires More to the sheet for shared-core (toggle, dialog, dock slot)" do
      get_html "/"
      more = doc.at(".tab-bar > button.tab-bar-item")
      expect(more.to_h).to include("type" => "button", "data-sheet-toggle" => "", "aria-controls" => "more-sheet",
                                   "aria-expanded" => "false", "aria-haspopup" => "dialog")
      expect(more.at(".tab-bar-label").text).to eq("More")
      sheet = doc.at("#more-sheet")
      expect(sheet.to_h).to include("class" => "sheet", "role" => "dialog", "aria-modal" => "true", "aria-label" => "More", "hidden" => "")
      expect(sheet.previous_element.to_h).to include("class" => "sheet-scrim", "hidden" => "")
      expect(sheet.at(".sheet-dock")).not_to be_nil
    end

    it "shows every item as a tab when there are four or fewer, and leaves the sheet list out" do
      get_html "/"
      expect(tabs.map { |a| a["href"] }).to eq(%w[/ /goals /settings])
      expect(doc.at("#more-sheet .nav-menu")).to be_nil
    end

    it "takes the tab: true items when an app marks them" do
      marked = five.each_with_index.map { |spec, i| [ 0, 2, 4 ].include?(i) ? spec.merge(tab: true) : spec }
      with_config(nav_items: marked) { get_html "/" }
      expect(tabs.map { |a| a["href"] }).to eq(%w[/ /plan /settings])
      expect(sheet_links).to eq(%w[/goals /archive])
    end

    it "skips tab: false items in the default pick" do
      with_config(nav_items: five.each_with_index.map { |s, i| i == 1 ? s.merge(tab: false) : s }) { get_html "/" }
      expect(tabs.map { |a| a["href"] }).to eq(%w[/ /plan /archive /settings])
    end

    it "honours tab_count" do
      with_config(nav_items: five, tab_count: 3) { get_html "/" }
      expect(tabs.size).to eq(3)
    end

    it "can be switched off (hamburger + drawer only)" do
      with_config(tab_bar: false) { get_html "/" }
      expect(doc.at(".tab-bar")).to be_nil
      expect(doc.at("#more-sheet")).to be_nil
      expect(doc.at("#mobileMenuBtn")).not_to be_nil
    end
  end

  describe "design system tags" do
    it "loads the pinned release from v/<sha>/ with integrity attributes (PLAT-26)" do
      release = PersonalAppClient::Configuration.shipped_ds_release
      with_config(ds_scripts: %w[session-render goal-render]) { get_html "/" }
      base = "https://design-system.joenguyen.ca/v/#{release['sha']}"
      core = doc.at("head script[src$='shared-core.js']")
      expect(core["src"]).to eq("#{base}/shared-core.js")
      expect(core["integrity"]).to eq(release["files"]["shared-core.js"])
      expect(core["crossorigin"]).to eq("anonymous")
      css = doc.css("head link[rel=stylesheet]").first
      expect(css["href"]).to eq("#{base}/design-system.css")
      expect(css["integrity"]).to eq(release["files"]["design-system.css"])
      expect(doc.at("head script[src$='apps-launcher.js']")["integrity"]).to start_with("sha384-")
    end

    it "loads shared-core, the configured extras and modal-keys in order, apps-launcher deferred" do
      with_config(ds_scripts: %w[session-render goal-render], ds_release: false) { get_html "/" }
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

    it "gives the launcher the app list from apps.json, before apps-launcher.js" do
      get_html "/"
      head = doc.at("head").element_children
      list = head.index { |el| el.name == "script" && el.text.include?("window.PERSONAL_APPS") }
      launcher = head.index { |el| el["src"].to_s.end_with?("apps-launcher.js") }
      expect(list).to be < launcher
      expect(doc.at("head").text).to include('"dock_name":"Meals"')
    end

    it "honours DS_BASE (unversioned, no integrity: a local design system in development)" do
      ENV["DS_BASE"] = "http://localhost:8804"
      get_html "/"
      expect(doc.css("head link[rel=stylesheet]").first["href"]).to eq("http://localhost:8804/design-system.css")
      expect(doc.css("head link[rel=stylesheet]").first["integrity"]).to be_nil
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
        with_config(ds_release: false) { get_html "/" }
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
    it "puts title + badge, actions and the subtitle in one inline grid (inline; PLAT-09)" do
      get_html "/"
      grid = doc.at("header.page-header > div.page-header-inline")
      expect(grid.element_children.map { |c| c["class"] }).to eq([ "page-header-title d-flex align-center gap-3", "header-actions", "page-subtitle" ])
      expect(grid.at("> div.page-header-title > h1").text).to eq("today")
      expect(grid.at("> p.page-subtitle").text).to eq("monday · 23 nov")
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
      expect(doc.at("header .page-header-inline > span.page-subtitle")).not_to be_nil
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
      # PLAT-06: live regions — a notice is a polite status, an alert assertive.
      expect(flashes.map { |f| [ f["role"], f["aria-live"] ] }).to eq([ %w[status polite], %w[alert assertive] ])
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

    it "installs the browser error hook before the design-system scripts" do
      get_html "/"
      head = doc.at("head").element_children
      hook = head.index { |el| el.name == "script" && el.text.include?("/api/client-errors") }
      first_ds = head.index { |el| el["src"].to_s.include?("shared-core") }
      expect(hook).to be < first_ds
    end

    it "omits the error hook when reporting is off" do
      PersonalAppClient.config.error_reporting.enabled = false
      get_html "/"
      expect(html).not_to include("/api/client-errors")
    ensure
      PersonalAppClient.config.error_reporting.enabled = true
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
