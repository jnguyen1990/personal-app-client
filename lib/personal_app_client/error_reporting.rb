require "digest"
require "time"
require "uri"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"
require_relative "revision"

module PersonalAppClient
  # Error visibility for the apps: unhandled exceptions, 5xx responses and
  # browser errors become a deduplicated event posted to base (the hub) —
  # the same road job statuses already travel.
  #
  # The engine installs it when `config.error_reporting.enabled?` (production
  # by default):
  #
  #   * a `Rails.error` subscriber — exceptions Rails reports itself (an
  #     unhandled controller exception rendered as a 500, a job that raised
  #     inside the executor) and anything an app reports with
  #     `Rails.error.report` / `record` at severity :error;
  #   * a `process_action.action_controller` subscriber for 5xx responses
  #     that were rendered rather than raised (`render status: 500`);
  #   * POST /api/client-errors, fed by the shell's window.onerror /
  #     unhandledrejection hook.
  #
  # Each event has a fingerprint (kind, class, first app frame without its
  # line number, normalised message). The first occurrence is sent; repeats
  # within `window` seconds are counted, and the next send after the window
  # carries the count. base keys its rows on (source_app, fingerprint).
  #
  # Delivery is `config.error_reporting.via` (a callable taking the payload)
  # or, by default, HubClient#report_error — on a background thread unless
  # `async` is false. A delivery failure is logged and dropped; reporting
  # never raises into the request or job that failed.
  module ErrorReporting
    GUARD = :personal_app_client_reporting
    MESSAGE_LIMIT = 1000
    BACKTRACE_LINES = 12

    # Counts repeats of a fingerprint inside a time window.
    class Deduper
      def initialize(window:, max_keys: 500, clock: nil)
        @window = window.to_f
        @max_keys = max_keys
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @entries = {}
        @mutex = Mutex.new
      end

      # The count to send — 1 the first time, 1 + the repeats suppressed
      # since the last send once the window has passed — or nil to suppress.
      def admit(fingerprint)
        @mutex.synchronize do
          now = @clock.call
          entry = @entries[fingerprint]
          if entry && now - entry[:sent_at] < @window
            entry[:suppressed] += 1
            return nil
          end

          count = 1 + (entry ? entry[:suppressed] : 0)
          @entries.delete(fingerprint)
          @entries[fingerprint] = { sent_at: now, suppressed: 0 }
          @entries.shift while @entries.size > @max_keys
          count
        end
      end

      def clear
        @mutex.synchronize { @entries.clear }
      end
    end

    class Reporter
      attr_reader :deduper, :config, :app_id

      def initialize(config:, app_id:, delivery: nil, clock: nil, logger: nil)
        @config = config
        @app_id = app_id.to_s
        @delivery = delivery
        @logger = logger
        @deduper = Deduper.new(window: config.window, clock: clock)
      end

      # The ActiveSupport::ErrorReporter subscriber interface.
      def report(error, handled:, severity:, context: {}, source: nil)
        return if Thread.current[GUARD]
        return if handled && severity.to_s != "error"
        return if ignored?(error)

        submit(ErrorReporting.exception_payload(error, handled: handled, severity: severity,
                                                       context: context || {}, source: source))
      rescue StandardError => e
        log("could not report #{error.class}: #{e.class}: #{e.message}")
        nil
      end

      # A process_action.action_controller payload. Only 5xx responses that
      # were rendered (no exception) — raised ones arrive through #report.
      def report_response(payload)
        return if Thread.current[GUARD]
        status = payload[:status].to_i
        return unless status >= 500
        return if payload[:exception] || payload[:exception_object]

        submit(ErrorReporting.response_payload(payload))
      rescue StandardError => e
        log("could not report a #{status} response: #{e.class}: #{e.message}")
        nil
      end

      # A browser error from POST /api/client-errors.
      def report_client(attrs)
        submit(ErrorReporting.client_payload(attrs))
      rescue StandardError => e
        log("could not report a client error: #{e.class}: #{e.message}")
        nil
      end

      # A Content-Security-Policy violation from POST /api/csp-reports.
      def report_csp(report)
        submit(ErrorReporting.csp_payload(report))
      rescue StandardError => e
        log("could not report a CSP violation: #{e.class}: #{e.message}")
        nil
      end

      # Dedupe, stamp, deliver. Returns the payload sent, or nil.
      def submit(payload)
        count = deduper.admit(payload[:fingerprint])
        return nil unless count

        payload = payload.merge(count: count, revision: PersonalAppClient.revision,
                                occurred_at: Time.now.utc.iso8601).compact
        if config.async
          Thread.new { deliver(payload) }
        else
          deliver(payload)
        end
        payload
      end

      private

      def deliver(payload)
        previous = Thread.current[GUARD]
        Thread.current[GUARD] = true
        with_executor { delivery.call(payload) }
      rescue StandardError => e
        log("delivery failed for #{payload[:error_class]}: #{e.class}: #{e.message}")
      ensure
        Thread.current[GUARD] = previous
      end

      def delivery
        @delivery || config.via || method(:deliver_to_hub)
      end

      def deliver_to_hub(payload)
        PersonalAppClient::HubClient.new(source_app: app_id).report_error(payload)
      end

      # Background threads need the executor for database connections (the
      # hub client reads its URL from Setting).
      def with_executor(&block)
        app = defined?(::Rails) && ::Rails.respond_to?(:application) ? ::Rails.application : nil
        app.respond_to?(:executor) ? app.executor.wrap(&block) : yield
      end

      def ignored?(error)
        names = error.class.ancestors.filter_map { |mod| mod.name if mod.is_a?(Class) }
        (names & Array(config.ignore).map(&:to_s)).any?
      end

      def log(message)
        logger = @logger || (defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil)
        logger&.warn("[PersonalAppClient::ErrorReporting] #{message}")
      end
    end

    class << self
      attr_reader :reporter

      # Subscribe to Rails.error and 5xx responses. Idempotent.
      def install!(config: PersonalAppClient.config.error_reporting, app_id: PersonalAppClient.config.app_id,
                   delivery: nil, clock: nil)
        return @reporter if @reporter

        @reporter = Reporter.new(config: config, app_id: app_id, delivery: delivery, clock: clock)
        ::Rails.error.subscribe(@reporter) if defined?(::Rails) && ::Rails.respond_to?(:error)
        if defined?(::ActiveSupport::Notifications)
          @subscription = ::ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
            @reporter&.report_response(event.payload)
          end
        end
        @reporter
      end

      def uninstall!
        return unless @reporter
        ::Rails.error.unsubscribe(@reporter) if defined?(::Rails) && ::Rails.respond_to?(:error)
        ::ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
        @reporter = @subscription = nil
      end

      def exception_payload(error, handled:, severity:, context:, source:)
        backtrace = clean_backtrace(error.backtrace)
        location = backtrace.first
        request_info = request_info(context)
        kind = context[:job] || source.to_s.include?("active_job") ? "job" : "server"
        {
          kind: kind,
          error_class: error.class.name,
          message: error.message.to_s.truncate(MESSAGE_LIMIT),
          location: location,
          backtrace: backtrace.first(BACKTRACE_LINES).join("\n").presence,
          severity: severity.to_s,
          handled: handled ? true : false,
          source: source.to_s.presence,
          fingerprint: fingerprint(kind, error.class.name, location, error.message)
        }.merge(request_info).compact
      end

      def response_payload(payload)
        origin = [ payload[:controller], payload[:action] ].compact.join("#")
        status = payload[:status].to_i
        {
          kind: "server",
          error_class: "HTTP #{status}",
          message: "#{origin} responded #{status}",
          origin: origin.presence,
          path: payload[:path].to_s.split("?").first.presence,
          request_method: payload[:method],
          status: status,
          severity: "error",
          handled: true,
          source: "process_action.action_controller",
          fingerprint: fingerprint("server", "HTTP #{status}", origin, "")
        }.compact
      end

      # attrs: message, source (script URL), line, col, stack, url (page),
      # kind ("error" / "unhandledrejection").
      def client_payload(attrs)
        attrs = attrs.to_h.transform_keys(&:to_s)
        raw = attrs["message"].to_s.squish.sub(/\AUncaught\s+/, "")
        klass, message = split_client_message(raw)
        klass ||= attrs["kind"].to_s == "unhandledrejection" ? "UnhandledRejection" : "Error"
        script = url_path(attrs["source"])
        location = script && [ script, attrs["line"].to_i, attrs["col"].to_i ].join(":")
        {
          kind: "client",
          error_class: klass,
          message: message.truncate(MESSAGE_LIMIT),
          location: location,
          backtrace: attrs["stack"].to_s.lines.first(BACKTRACE_LINES).join.truncate(4000).presence,
          origin: "browser",
          path: url_path(attrs["url"]),
          severity: "error",
          handled: false,
          source: "window.#{attrs['kind'].presence || 'error'}",
          fingerprint: fingerprint("client", klass, location, message)
        }.compact
      end

      # One violation report → an error event. Fingerprinted on the directive,
      # the blocked origin (not its full URL) and the page, so one bad script
      # on one page is one row however often it fires.
      def csp_payload(report)
        r = report.to_h.transform_keys(&:to_s)
        directive = (r["effective-directive"].presence || r["violated-directive"].to_s.split.first).to_s
        blocked = r["blocked-uri"].to_s
        blocked_origin = begin
          u = URI.parse(blocked)
          u.host ? "#{u.scheme}://#{u.host}" : blocked
        rescue URI::InvalidURIError
          blocked
        end
        page = url_path(r["document-uri"])
        message = "#{directive} blocked #{blocked_origin.presence || '(unknown)'}"
        script = url_path(r["source-file"])
        location = script && [ script, r["line-number"].to_i, r["column-number"].to_i ].join(":")
        {
          kind: "client",
          error_class: "CSPViolation",
          message: message.truncate(MESSAGE_LIMIT),
          location: location,
          origin: "browser",
          path: page,
          severity: r["disposition"].to_s == "report" ? "warning" : "error",
          handled: r["disposition"].to_s == "report",
          source: "csp.#{r['disposition'].presence || 'enforce'}",
          fingerprint: fingerprint("csp", directive, page, blocked_origin)
        }.compact
      end

      def fingerprint(kind, error_class, location, message)
        frame = location.to_s.sub(/:\d+(?::\d+)?(?=:in |\z)/, "")
        Digest::SHA256.hexdigest([ kind, error_class, frame, normalize(message) ].join("|"))[0, 16]
      end

      # Digits and hex ids vary between occurrences of one bug.
      def normalize(message)
        message.to_s.gsub(/0x[0-9a-f]+/i, "0x").gsub(/\d+/, "0").squish[0, 200]
      end

      private

      def clean_backtrace(backtrace)
        lines = Array(backtrace)
        return [] if lines.empty?
        if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner) && ::Rails.backtrace_cleaner
          cleaned = ::Rails.backtrace_cleaner.clean(lines)
          return cleaned if cleaned.any?
        end
        lines.map { |line| shorten_gem_path(line) }
      end

      def shorten_gem_path(line)
        Gem.path.reduce(line) { |acc, dir| acc.sub("#{dir}/gems/", "") }
      end

      def request_info(context)
        if (controller = context[:controller]) && controller.respond_to?(:request) && controller.request
          req = controller.request
          { origin: [ controller.class.name, (controller.action_name if controller.respond_to?(:action_name)) ].compact.join("#"),
            path: req.path, request_method: req.request_method }
        elsif (job = context[:job])
          { origin: job.class.name }
        else
          {}
        end
      end

      def split_client_message(raw)
        match = raw.match(/\A([A-Z][\w$]*(?:Error|Exception))(?::\s*|\z)(.*)\z/m)
        match ? [ match[1], match[2].to_s ] : [ nil, raw ]
      end

      def url_path(value)
        return nil if value.blank?
        value.to_s.sub(%r{\A[a-z][a-z0-9+.-]*://[^/]+}i, "").split(/[?#]/).first.presence
      end
    end
  end
end
