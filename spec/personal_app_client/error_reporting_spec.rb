require "personal_app_client/error_reporting"

RSpec.describe PersonalAppClient::ErrorReporting do
  describe PersonalAppClient::ErrorReporting::Deduper do
    let(:now) { [ 0.0 ] }
    let(:deduper) { described_class.new(window: 60, clock: -> { now[0] }, max_keys: 2) }

    it "sends the first, counts repeats in the window, sends the count after it" do
      expect(deduper.admit("a")).to eq(1)
      expect(deduper.admit("a")).to be_nil
      expect(deduper.admit("a")).to be_nil
      now[0] = 61
      expect(deduper.admit("a")).to eq(3)
      expect(deduper.admit("a")).to be_nil
    end

    it "tracks fingerprints separately and forgets the oldest past max_keys" do
      expect(deduper.admit("a")).to eq(1)
      expect(deduper.admit("b")).to eq(1)
      expect(deduper.admit("c")).to eq(1)
      expect(deduper.admit("a")).to eq(1) # evicted, so new again
    end
  end

  describe ".fingerprint" do
    it "ignores line numbers, digits and object ids" do
      a = described_class.fingerprint("server", "NoMethodError", "app/models/item.rb:12:in 'Item#due'",
                                      "undefined method 'x' for #<Item id: 4 0x00007f>")
      b = described_class.fingerprint("server", "NoMethodError", "app/models/item.rb:99:in 'Item#due'",
                                      "undefined method 'x' for #<Item id: 81 0x0000aa>")
      expect(a).to eq(b)
      expect(a).to match(/\A\h{16}\z/)
    end

    it "differs by class, frame and kind" do
      base = [ "server", "NoMethodError", "app/a.rb:1:in 'f'", "m" ]
      variants = [ [ "job", *base[1..] ], [ base[0], "TypeError", *base[2..] ], [ *base[0..1], "app/b.rb:1:in 'f'", "m" ] ]
      prints = ([ base ] + variants).map { |args| described_class.fingerprint(*args) }
      expect(prints.uniq.size).to eq(4)
    end
  end

  describe ".client_payload" do
    it "splits the class out of the browser message and keeps the script path only" do
      payload = described_class.client_payload(
        "kind" => "error", "message" => "Uncaught ReferenceError: dsToast is not defined",
        "source" => "https://budgeter.joenguyen.ca/assets/budgeter-1a2b.js?x=1", "line" => "7", "col" => 3,
        "url" => "/settings?tab=1#data"
      )
      expect(payload).to include(kind: "client", error_class: "ReferenceError", message: "dsToast is not defined",
                                 location: "/assets/budgeter-1a2b.js:7:3", path: "/settings", handled: false)
    end

    it "names an unhandled rejection without an Error class" do
      payload = described_class.client_payload("kind" => "unhandledrejection", "message" => "HTTP error! status: 500")
      expect(payload).to include(error_class: "UnhandledRejection", message: "HTTP error! status: 500",
                                 source: "window.unhandledrejection")
      expect(payload).not_to have_key(:location)
    end
  end

  describe ".response_payload" do
    it "describes a rendered 5xx" do
      payload = described_class.response_payload(controller: "Api::BackupsController", action: "create_backup",
                                                 status: 500, path: "/api/backup/create?x=1", method: "GET")
      expect(payload).to include(error_class: "HTTP 500", origin: "Api::BackupsController#create_backup",
                                 path: "/api/backup/create", status: 500, request_method: "GET")
    end
  end

  describe PersonalAppClient::ErrorReporting::Reporter do
    let(:sent) { [] }
    let(:config) do
      PersonalAppClient::Configuration::ErrorReportingConfig.new.tap { |c| c.async = false }
    end
    let(:reporter) { described_class.new(config: config, app_id: "upkeep", delivery: ->(p) { sent << p }) }

    def raised(klass = RuntimeError, message = "boom")
      raise klass, message
    rescue klass => e
      e
    end

    it "reports unhandled errors and severity-error reports, not handled warnings" do
      reporter.report(raised, handled: false, severity: :error, context: {}, source: "application.action_dispatch")
      reporter.report(raised(ArgumentError), handled: true, severity: :warning, context: {}, source: "x")
      reporter.report(raised(TypeError), handled: true, severity: :error, context: {}, source: "x")
      expect(sent.map { |p| p[:error_class] }).to eq(%w[RuntimeError TypeError])
      expect(sent.first).to include(kind: "server", count: 1, handled: false)
    end

    it "skips ignored classes, including subclasses" do
      stub_const("ActiveRecord::RecordNotFound", Class.new(StandardError))
      stub_const("MyNotFound", Class.new(ActiveRecord::RecordNotFound))
      reporter.report(raised(MyNotFound), handled: false, severity: :error, context: {})
      expect(sent).to be_empty
    end

    it "marks job errors" do
      stub_const("SyncDueToBaseJob", Class.new)
      reporter.report(raised, handled: false, severity: :error, context: { job: SyncDueToBaseJob.new },
                              source: "application.active_job")
      expect(sent.first).to include(kind: "job", origin: "SyncDueToBaseJob")
    end

    it "ignores 5xx responses that carried an exception (already reported) and non-5xx" do
      reporter.report_response(status: 500, exception: [ "RuntimeError", "x" ], controller: "A", action: "b")
      reporter.report_response(status: 404, controller: "A", action: "b")
      reporter.report_response(status: 503, controller: "A", action: "b", path: "/a")
      expect(sent.map { |p| p[:error_class] }).to eq([ "HTTP 503" ])
    end

    it "swallows a failing delivery" do
      failing = described_class.new(config: config, app_id: "x", delivery: ->(_p) { raise "down" })
      expect { failing.report(raised, handled: false, severity: :error, context: {}) }.not_to raise_error
    end

    it "posts through HubClient by default" do
      hub = instance_double(PersonalAppClient::HubClient, report_error: nil)
      allow(PersonalAppClient::HubClient).to receive(:new).with(source_app: "upkeep").and_return(hub)
      described_class.new(config: config, app_id: "upkeep")
                     .report(raised, handled: false, severity: :error, context: {})
      expect(hub).to have_received(:report_error).with(hash_including(error_class: "RuntimeError", count: 1))
    end
  end
end
