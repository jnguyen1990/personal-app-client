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

    def personal_app_ds_url(file)
      "#{personal_app_config.ds_base}/#{file}"
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
