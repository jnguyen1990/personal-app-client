require "uri"

module PersonalAppClient
  # The Content-Security-Policy every app sends (PLAT-25). The apps write
  # into innerHTML in ~160 places; without a policy, anything injected there
  # could load code from, or send data to, any site. This limits scripts and
  # fetches to the app itself and the design-system host (which also serves
  # the vendored Chart.js and Leaflet). Inline scripts and handlers stay
  # allowed — every page uses them — so the policy closes the "load or send
  # anywhere" hole, not inline injection itself.
  #
  # config.content_security_policy: :report_only (default — the browser
  # reports, blocks nothing), :enforce, or false. An app's own policy in
  # config/initializers/content_security_policy.rb always wins. Violations
  # go to POST /api/csp-reports and on to base's /errors page.
  module Csp
    REPORT_PATH = "/api/csp-reports".freeze

    module_function

    def apply!(app, config = PersonalAppClient.config)
      mode = config.content_security_policy
      return nil if mode == false || mode.nil?
      return nil if app.config.content_security_policy # the app configured its own

      # Rails' config.content_security_policy is a block-taking method, not a writer.
      app.config.content_security_policy(&directives(config))
      app.config.content_security_policy_report_only = (mode.to_s != "enforce")
      app.config.content_security_policy
    end

    def build(config = PersonalAppClient.config)
      ActionDispatch::ContentSecurityPolicy.new(&directives(config))
    end

    def directives(config)
      ds = config.ds_origin
      extra = config.content_security_policy_extra
      lambda do |p|
        p.default_src :self
        p.script_src  :self, :unsafe_inline, ds
        p.style_src   :self, :unsafe_inline, ds
        p.font_src    :self, :data, ds
        # Images may come from anywhere https (recipe photos, map tiles,
        # thumbnails): an image cannot run code.
        p.img_src     :self, :data, :blob, :https, ds
        p.connect_src :self, ds
        p.worker_src  :self
        p.manifest_src :self
        p.frame_src   :self
        p.object_src  :none
        p.base_uri    :self
        p.frame_ancestors :self
        p.report_uri  REPORT_PATH
        extra&.call(p)
      end
    end
  end
end
