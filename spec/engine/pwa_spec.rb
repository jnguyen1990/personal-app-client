RSpec.describe "PWA" do
  it "serves the manifest from config" do
    get "/manifest.json"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["Content-Type"]).to start_with("application/manifest+json")
    expect(json).to include("name" => "Dummy", "short_name" => "Dummy", "start_url" => "/", "scope" => "/",
                            "display" => "standalone", "theme_color" => "#ffffff")
    expect(json["icons"].map { |i| i["src"] }).to eq(%w[/icon.png /icon.png /icon.svg])
  end

  it "serves the shared service worker, uncached, with a per-release cache name" do
    get "/service-worker.js"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["Content-Type"]).to start_with("text/javascript")
    expect(last_response.headers["Cache-Control"]).to eq("no-cache")
    body = last_response.body
    expect(body).to include(%(const CACHE = "pa-dummy-#{PersonalAppClient::VERSION}))
    expect(body).to include(%(const OFFLINE_URL = "/offline"))
    expect(body).to include("https://design-system.joenguyen.ca", "https://fonts.gstatic.com")
    expect(body).to include("staleWhileRevalidate", "networkFirst")
    expect(body).not_to include("unregister()")
  end

  it "includes a DS_BASE origin with its port" do
    ENV["DS_BASE"] = "http://localhost:8804"
    get "/service-worker.js"
    expect(last_response.body).to include(%("http://localhost:8804"))
  ensure
    ENV.delete("DS_BASE")
  end

  it "serves a self-removing worker as the kill switch" do
    PersonalAppClient.config.pwa.service_worker = :unregister
    get "/service-worker.js"
    expect(last_response.body).to include("self.registration.unregister()")
    expect(last_response.body).not_to include("networkFirst")
  ensure
    PersonalAppClient.config.pwa.service_worker = true
  end

  it "404s the worker when switched off" do
    PersonalAppClient.config.pwa.service_worker = false
    get "/service-worker.js"
    expect(last_response.status).to eq(404)
  ensure
    PersonalAppClient.config.pwa.service_worker = true
  end

  it "is production-only by default" do
    PersonalAppClient.config.pwa.service_worker = nil
    expect(PersonalAppClient.config.pwa.service_worker_mode).to be(false)
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(PersonalAppClient.config.pwa.service_worker_mode).to be(true)
  ensure
    PersonalAppClient.config.pwa.service_worker = true
  end

  it "has an offline page" do
    get "/offline"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("You're offline", "Dummy can't be reached right now")
  end
end
