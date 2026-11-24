module PersonalAppClient
  # Third-party libraries the apps use, self-hosted on the design-system host
  # under /vendor/ (design-system repo, PLAT-11) instead of a public CDN:
  # pinned paths, a year of immutable caching, and an integrity hash each, so
  # a third party can no longer run code inside a signed-in page. Emitted by
  # ShellHelper#personal_app_vendor_tags (and _json for loading on demand).
  module Vendor
    LIBS = {
      "chart.js" => {
        path: "vendor/chart.js-4.6.1/chart.umd.min.js",
        integrity: "sha384-Emf5ZVIUiarAdhkgtqK+5/Z5qIvM6QoVrS+qAVtfyZVuD5lIHrac0me485+Antp0"
      },
      "leaflet.js" => {
        path: "vendor/leaflet-1.9.4/leaflet.js",
        integrity: "sha384-cxOPjt7s7Iz04uaHJceBmS+qpjv2JkIHNVcuOrM+YHwZOmJGBXI00mdUXEq65HTH"
      },
      "leaflet.css" => {
        path: "vendor/leaflet-1.9.4/leaflet.css",
        integrity: "sha384-sHL9NAb7lN7rfvG5lfHpm643Xkcjzp4jFvuavGOndn6pjVqS6ny56CAt3nsEVT4H"
      }
    }.freeze

    def self.fetch(name)
      LIBS.fetch(name.to_s) { raise ArgumentError, "unknown vendored library #{name.inspect} (have: #{LIBS.keys.join(', ')})" }
    end
  end
end
