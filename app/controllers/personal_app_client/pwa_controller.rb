module PersonalAppClient
  # GET /manifest.json, /service-worker.js and /offline — one shared PWA
  # shell for every app (config.app_name, config.pwa).
  #
  # ActionController::Base, not the app's ApplicationController: these must
  # answer for any browser, and Rails' CSRF guard refuses to serve a GET
  # JavaScript response to a non-XHR request (which a service-worker
  # registration is).
  class PwaController < ActionController::Base
    skip_forgery_protection
    layout false

    def manifest
      expires_in 1.hour, public: false
      render template: "personal_app_client/pwa/manifest", formats: [ :json ],
             content_type: "application/manifest+json"
    end

    def service_worker
      mode = PersonalAppClient.config.pwa.service_worker_mode
      return head(:not_found) unless mode

      @unregister = mode == :unregister
      @cache_name = [ "pa", PersonalAppClient.config.app_id, PersonalAppClient::VERSION,
                      PersonalAppClient.revision.to_s[0, 12].presence ].compact.join("-")
      response.headers["Cache-Control"] = "no-cache"
      render template: "personal_app_client/pwa/service_worker", formats: [ :js ],
             content_type: "text/javascript"
    end

    def offline
      render template: "personal_app_client/pwa/offline", formats: [ :html ]
    end
  end
end
