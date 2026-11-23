module Dummy
  # What the error reporter delivered (engine specs read and clear it).
  DELIVERED_ERRORS = []
end

PersonalAppClient.configure do |app|
  app.app_id = "dummy"
  app.app_name = "Dummy"
  app.nav_items = [
    { path: "/",         label: "today",    ico: "star",    key: "1" },
    { path: "/goals",    label: "goals",    ico: "target",  key: "2", active: :prefix },
    { path: "/settings", label: "settings", ico: "sliders", key: "," }
  ]
  app.health_targets = -> { [ probe_client("base", BaseAppClient.new) ] }
  app.backup = { extra_files: %w[README.md] }
  app.rate_limit = { limit: 1000 }

  app.error_reporting.enabled = true
  app.error_reporting.async = false
  app.error_reporting.via = ->(payload) { Dummy::DELIVERED_ERRORS << payload }

  app.pwa.service_worker = true
end
