module PersonalAppClient
  # One line per request (PLAT-51), key=value so it greps and sorts:
  #
  #   request method=GET path=/api/transactions status=200 duration_ms=41.2 db_ms=6.1 view_ms=12.0 controller=Api::TransactionsController#index
  #
  # Rails' own lines are kept; this adds a summary that holds timing and
  # volume in one place for `journalctl -u <app> | grep ' request '`.
  # On in production by default (config.request_log).
  module RequestLog
    module_function

    def install!(logger: nil)
      return if @subscriber

      @subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        (logger || ::Rails.logger)&.info(line(event))
      rescue StandardError
        nil
      end
    end

    def uninstall!
      ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
      @subscriber = nil
    end

    def line(event)
      p = event.payload
      status = p[:status] || (p[:exception] ? 500 : nil)
      fields = {
        method: p[:method], path: p[:path].to_s.split("?").first, status: status,
        duration_ms: event.duration&.round(1), db_ms: p[:db_runtime]&.round(1),
        view_ms: p[:view_runtime]&.round(1), controller: "#{p[:controller]}##{p[:action]}"
      }
      fields[:error] = Array(p[:exception]).first if p[:exception]
      "request " + fields.compact.map { |k, v| "#{k}=#{v.to_s.gsub(/\s+/, '_')}" }.join(" ")
    end
  end
end
