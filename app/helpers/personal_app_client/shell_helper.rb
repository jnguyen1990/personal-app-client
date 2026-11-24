module PersonalAppClient
  # View helpers behind the shared shell (layouts/personal_app/shell) and the
  # settings-pane partials. Included in every ActionController::Base view by
  # the engine.
  module ShellHelper
    def personal_app_config
      PersonalAppClient.config
    end

    # "<page title> · <app>" or just "<app>" — the <title> every app had.
    def personal_app_title
      [ content_for(:page_title).presence, personal_app_config.app_id ].compact.join(" · ")
    end

    # Nav::Item structs for the sidebar, with the active one marked.
    def personal_app_nav_items
      specs = personal_app_config.nav_items
      specs = instance_exec(&specs) if specs.respond_to?(:call)
      PersonalAppClient::Nav.items(specs, request.path)
    end

    # The mobile tab bar's items (Nav.tabs), or [] when config.tab_bar is off.
    def personal_app_tab_items(items = personal_app_nav_items)
      return [] unless personal_app_config.tab_bar
      PersonalAppClient::Nav.tabs(items, personal_app_config.tab_count.to_i.clamp(1, 5))
    end

    # <meta name="ds-palette" content="…">: turns the ⌘K palette on for this
    # page; content is the search URL, or "" when the app has no config.search
    # (the palette still lists pages and actions). Nothing when off.
    def personal_app_palette_meta_tag
      return unless personal_app_config.palette
      url = personal_app_config.search && respond_to?(:api_search_path) ? api_search_path : ""
      tag.meta(name: "ds-palette", content: url)
    end

    # The palette's open control (sidebar and the phone "More" sheet).
    def personal_app_palette_trigger(css = "palette-trigger")
      return unless personal_app_config.palette
      content_tag(:button, type: "button", class: css, data: { palette_open: "" }, "aria-keyshortcuts": "Meta+K") do
        safe_join([ content_tag(:span, "", class: "nav-ico", data: { ico: "search" }, "aria-hidden": "true"),
                    content_tag(:span, "Search"), content_tag(:kbd, "⌘K", class: "kbd") ])
      end
    end

    # window.PERSONAL_APPS for the launcher dock (apps-launcher.js), from
    # apps.json — the one list of apps (PLAT-44).
    def personal_app_apps_tag
      content_tag(:script, "window.PERSONAL_APPS = #{PersonalAppClient::Apps.for_launcher.to_json};".html_safe)
    end

    # A design-system file's URL: <ds_base>/v/<sha>/<file> when the pinned
    # release (config.ds_release) has it, else the unversioned <ds_base>/<file>.
    def personal_app_ds_url(file)
      release = personal_app_config.ds_release
      if release && release.dig("files", file)
        "#{personal_app_config.ds_base}/v/#{release['sha']}/#{file}"
      else
        "#{personal_app_config.ds_base}/#{file}"
      end
    end

    # ' integrity="sha384-…" crossorigin="anonymous"' for a pinned file, else
    # "". The browser refuses a file whose bytes do not match (PLAT-26).
    def personal_app_ds_sri(file)
      integrity = personal_app_config.ds_release&.dig("files", file)
      return "" unless integrity
      %( integrity="#{ERB::Util.html_escape(integrity)}" crossorigin="anonymous").html_safe
    end

    # <script>/<link> tags for vendored libraries on the design-system host
    # (Vendor::LIBS), each pinned with its integrity hash (PLAT-11):
    #     <%= personal_app_vendor_tags "chart.js" %>
    def personal_app_vendor_tags(*names)
      tags = names.map do |name|
        lib = PersonalAppClient::Vendor.fetch(name)
        url = "#{personal_app_config.ds_base}/#{lib[:path]}"
        if lib[:path].end_with?(".css")
          tag.link(rel: "stylesheet", href: url, integrity: lib[:integrity], crossorigin: "anonymous")
        else
          tag.script("", src: url, integrity: lib[:integrity], crossorigin: "anonymous")
        end
      end
      safe_join(tags, "\n    ")
    end

    # { "leaflet.js" => { "url" => …, "integrity" => … }, … } as JSON, for a
    # page that loads a library only when it needs it (fitness's route map).
    def personal_app_vendor_json(*names)
      names.to_h do |name|
        lib = PersonalAppClient::Vendor.fetch(name)
        [ name, { "url" => "#{personal_app_config.ds_base}/#{lib[:path]}", "integrity" => lib[:integrity] } ]
      end.to_json.html_safe
    end

    # The local fallback copy of a design-system file (public/ds/<file>).
    def personal_app_ds_fallback_url(file)
      "/ds/#{file}"
    end

    # True when config.ds_fallback is on and `personal_app:ds:snapshot` has
    # written public/ds/. Without the snapshot the shell emits the plain tags.
    def personal_app_ds_fallback?
      return false unless personal_app_config.ds_fallback
      PersonalAppClient::ShellHelper.snapshot_present?
    end

    def self.snapshot_present?
      return @snapshot_present unless @snapshot_present.nil?
      present = defined?(::Rails) && ::Rails.root &&
                File.exist?(::Rails.root.join("public", "ds", "design-system.css"))
      # Memoized in production (the snapshot is written before the restart);
      # looked up every time elsewhere so a fresh snapshot shows in dev.
      @snapshot_present = present if ::Rails.env.production?
      present ? true : false
    end

    def self.reset_snapshot_cache!
      @snapshot_present = nil
    end

    # onerror for the stylesheet <link>: swap to the local snapshot.
    def personal_app_ds_css_onerror
      "this.onerror=null;this.href='#{personal_app_ds_fallback_url('design-system.css')}'"
    end

    # onerror for a deferred script: load the local copy instead.
    def personal_app_ds_deferred_onerror(file)
      "this.onerror=null;var s=document.createElement('script');" \
        "s.src='#{personal_app_ds_fallback_url(file)}';document.head.appendChild(s)"
    end

    # Runs right after the synchronous DS scripts. If shared-core did not
    # define its globals the CDN failed, so the parser writes the local copies
    # in at the same point (document.write keeps them synchronous and in order).
    def personal_app_ds_sync_fallback_script
      tags = personal_app_config.ds_sync_scripts.map do |name|
        %(<script src="#{personal_app_ds_fallback_url("#{name}.js")}"><\\/script>)
      end
      "<script>window.installNavHotkeys||document.write('#{tags.join}')</script>".html_safe
    end

    # <meta name="theme-color"> for each scheme (the page background), then
    # a script that pins them to the app's own theme — the one shared-core
    # booted from localStorage, which need not match the OS — and follows
    # ds:themechange. Without JS the media queries still pick by OS scheme.
    def personal_app_theme_color_tags
      colors = (personal_app_config.pwa.theme_colors || {}).to_h.transform_keys(&:to_s)
      metas = colors.map do |scheme, color|
        tag.meta(name: "theme-color", content: color, media: "(prefers-color-scheme: #{scheme})")
      end
      return safe_join(metas, "\n    ") unless colors["light"] && colors["dark"]

      script = content_tag(:script, <<~JS.strip.html_safe)
        (function () {
          var colors = #{colors.slice('light', 'dark').to_json};
          function pin(theme) {
            document.querySelectorAll('meta[name="theme-color"]').forEach(function (m) { m.removeAttribute('media'); m.setAttribute('content', colors[theme] || colors.light); });
          }
          pin(document.documentElement.classList.contains('dark') ? 'dark' : 'light');
          document.addEventListener('ds:themechange', function (e) { pin(e.detail && e.detail.theme); });
        })();
      JS
      safe_join(metas + [ script ], "\n    ")
    end

    # The manifest link, when the PWA routes are drawn. use-credentials so
    # the Cloudflare Access cookie goes with it (an anonymous fetch would be
    # redirected to the Access login).
    def personal_app_manifest_tag
      return unless respond_to?(:pwa_manifest_path)
      tag.link(rel: "manifest", href: pwa_manifest_path, crossorigin: "use-credentials")
    end

    # Registers (or, as a kill switch, unregisters) the shared service worker.
    def personal_app_service_worker_tag
      return unless respond_to?(:pwa_service_worker_path)
      case personal_app_config.pwa.service_worker_mode
      when :unregister
        content_tag(:script, <<~JS.strip.html_safe)
          if ('serviceWorker' in navigator) navigator.serviceWorker.getRegistrations().then(function (rs) { rs.forEach(function (r) { r.unregister(); }); });
        JS
      when true
        content_tag(:script, <<~JS.strip.html_safe)
          if ('serviceWorker' in navigator) window.addEventListener('load', function () { navigator.serviceWorker.register('#{pwa_service_worker_path}').catch(function () {}); });
        JS
      end
    end

    # window.onerror / unhandledrejection → POST /api/client-errors. First in
    # <head> so it also sees errors thrown by the design-system scripts. At
    # most five reports per page load; "Script error." (a cross-origin script
    # without CORS) carries nothing worth sending.
    def personal_app_error_hook_tag
      return unless respond_to?(:api_client_errors_path)
      reporting = personal_app_config.error_reporting
      return unless reporting.enabled? && reporting.client_errors

      content_tag(:script, <<~JS.strip.html_safe)
        (function () {
          var sent = 0, url = '#{api_client_errors_path}';
          function send(data) {
            if (sent++ >= 5) return;
            try {
              var body = JSON.stringify(data);
              if (navigator.sendBeacon && navigator.sendBeacon(url, new Blob([body], { type: 'application/json' }))) return;
              fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body, keepalive: true, credentials: 'same-origin' });
            } catch (_) {}
          }
          window.addEventListener('error', function (e) {
            if (!e.message || e.message === 'Script error.') return;
            send({ kind: 'error', message: String(e.message), source: e.filename || '', line: e.lineno || 0, col: e.colno || 0,
                   stack: e.error && e.error.stack ? String(e.error.stack) : '', url: location.pathname });
          });
          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason;
            send({ kind: 'unhandledrejection', message: String(r && r.message ? r.message : r),
                   stack: r && r.stack ? String(r.stack) : '', url: location.pathname });
          });
        })();
      JS
    end

    # The page subtitle in the configured tag (:p or :span).
    def personal_app_subtitle_tag(content)
      tag_name = personal_app_config.subtitle_tag.to_s == "span" ? :span : :p
      content_tag(tag_name, content, class: "page-subtitle")
    end

    # --- field-level errors (PLAT-07) ---------------------------------------
    # The server-rendered twin of shared-core's dsFieldErrors: an invalid field
    # gets aria-invalid and aria-describedby pointing at a .form-error under it.
    #
    #   <%= f.text_field :title, class: "form-control", **personal_app_field_aria(@recipe, :title) %>
    #   <%= personal_app_field_error @recipe, :title %>
    #
    # (or render "personal_app/field_error", object: @recipe, attribute: :title)
    def personal_app_field_error_id(object, attribute)
      "#{object.model_name.param_key}_#{attribute}_error"
    end

    # { "aria-invalid": "true", "aria-describedby": "<id>" } when the attribute
    # has errors, else {} — splat it into the field's options.
    def personal_app_field_aria(object, attribute)
      return {} unless object.respond_to?(:errors) && object.errors.include?(attribute)
      { "aria-invalid": "true", "aria-describedby": personal_app_field_error_id(object, attribute) }
    end

    # <p class="form-error" id="…">Title can't be blank</p>, or nil.
    def personal_app_field_error(object, attribute)
      return unless object.respond_to?(:errors) && object.errors.include?(attribute)
      content_tag(:p, object.errors.full_messages_for(attribute).join(" · "),
                  class: "form-error", id: personal_app_field_error_id(object, attribute))
    end

    # --- settings panes ----------------------------------------------------

    def personal_app_mcp_url
      "#{request.base_url}/api/mcp"
    end

    # [{ name:, description: }] from the configured tool registry, or from
    # `tools` (tool classes, descriptor Hashes, or a registry).
    def personal_app_mcp_tools(tools = nil)
      tools ||= begin
        registry = personal_app_config.mcp_tool_registry
        registry = registry.constantize if registry.is_a?(String)
        registry = registry.call if registry.respond_to?(:call) && !registry.respond_to?(:tools)
        registry
      end
      tools = tools.tools if tools.respond_to?(:tools)
      Array(tools).map do |tool|
        if tool.respond_to?(:tool_name)
          { name: tool.tool_name, description: tool.description }
        else
          tool = tool.to_h
          { name: tool[:name] || tool["name"], description: tool[:description] || tool["description"] }
        end
      end
    end

    # First sentence of a tool description, at most 150 characters.
    def personal_app_tool_summary(description)
      description.to_s.split(/(?<=[.!?])\s+(?=[A-Z])/).first.to_s.truncate(150)
    end
  end
end
