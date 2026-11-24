# The macro must draw exactly what the apps wrote by hand on v0.7.0 — same
# verbs, paths, names and constraints — so adopting it changes no URL.
RSpec.describe "personal_app_routes" do
  def draw(&block)
    set = ActionDispatch::Routing::RouteSet.new
    set.draw(&block)
    set.routes.map do |r|
      { verb: r.verb, path: r.path.spec.to_s, name: r.name,
        to: "#{r.defaults[:controller]}##{r.defaults[:action]}",
        constraints: r.constraints.except(:request_method).transform_values(&:to_s) }
    end
  end

  # The ten routes as they stood in upkeep / the template on v0.7.0.
  let(:hand_written) do
    draw do
      get "/.well-known/oauth-protected-resource", to: "well_known#protected_resource"
      get "up" => "rails/health#show", as: :rails_health_check
      namespace :api do
        post "mcp", to: "mcp#handle"
        get "health/inter-app", to: "health#inter_app"
        get  "backup/create", to: "backups#create_backup"
        get  "backup/download/:filename", to: "backups#download", constraints: { filename: %r{[^/]+} }
        get  "backup/list", to: "backups#list"
        post "backup/prune", to: "backups#prune"
        post "backup/restore", to: "backups#restore"
        post "backup/restore-upload", to: "backups#restore_upload"
      end
    end
  end

  it "matches the hand-written routes when pointed at the apps' own controllers" do
    macro = draw do
      personal_app_routes well_known: "well_known", mcp: "api/mcp", health: "api/health",
                          backups: "api/backups", pwa: false, client_errors: false
    end
    expect(macro).to match_array(hand_written)
  end

  it "keeps paths, verbs and names with the engine's default controllers" do
    macro = draw { personal_app_routes pwa: false, client_errors: false }
    strip = ->(routes) { routes.map { |r| r.except(:to) } }
    expect(strip.call(macro)).to match_array(strip.call(hand_written))
    expect(macro.map { |r| r[:to] }).to include(
      "personal_app_client/well_known#protected_resource", "personal_app_client/mcp#handle",
      "personal_app_client/health#inter_app", "personal_app_client/backups#restore_upload",
      "rails/health#show"
    )
  end

  it "adds the PWA and client-error routes by default" do
    macro = draw { personal_app_routes }
    added = macro.map { |r| [ r[:verb], r[:path], r[:name] ] } - hand_written.map { |r| [ r[:verb], r[:path], r[:name] ] }
    expect(added).to match_array([
      [ "GET", "/manifest.json", "pwa_manifest" ],
      [ "GET", "/service-worker.js", "pwa_service_worker" ],
      [ "GET", "/offline(.:format)", "pwa_offline" ],
      [ "POST", "/api/client-errors(.:format)", "api_client_errors" ],
      [ "POST", "/api/csp-reports(.:format)", "api_csp_reports" ]
    ])
  end

  it "skips a group set to false" do
    macro = draw { personal_app_routes mcp: false, backups: false, well_known: false }
    paths = macro.map { |r| r[:path] }
    expect(paths.grep(/mcp|backup|well-known/)).to be_empty
    expect(paths).to include("/api/health/inter-app(.:format)")
  end

  it "rejects an unknown option" do
    expect { draw { personal_app_routes backup: "api/backups" } }.to raise_error(ArgumentError, /backup/)
  end

  it "has a non-DSL form" do
    macro = draw { PersonalAppClient.routes(self, pwa: false, client_errors: false) }
    expect(macro.size).to eq(hand_written.size)
  end

  it "is what the dummy app draws" do
    names = Rails.application.routes.routes.map(&:name).compact
    expect(names).to include("rails_health_check", "api_mcp", "api_health_inter_app", "api_backup_create",
                             "api_backup_restore_upload", "pwa_manifest", "api_client_errors")
  end
end
