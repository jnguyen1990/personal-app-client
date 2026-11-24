module PersonalAppClient
  # POST /api/client-errors — the shell's window.onerror /
  # unhandledrejection hook. Always 204 (a browser has nothing to do with the
  # answer); the error is passed to ErrorReporting when reporting is on.
  class ClientErrorsController < PersonalAppClient.api_base_controller
    MAX_BODY = 16 * 1024
    FIELDS = %w[message source line col stack url kind].freeze

    def create
      reporter = PersonalAppClient::ErrorReporting.reporter
      if reporter && PersonalAppClient.config.error_reporting.client_errors &&
         request.content_length.to_i <= MAX_BODY
        attrs = request.request_parameters.slice(*FIELDS)
        reporter.report_client(attrs) if attrs["message"].present?
      end
      head :no_content
    end

    # POST /api/csp-reports — a browser's Content-Security-Policy violation
    # report ({"csp-report": {...}}, Content-Type application/csp-report,
    # which Rails does not parse). Reported like a client error, kind "csp".
    def csp
      reporter = PersonalAppClient::ErrorReporting.reporter
      if reporter && request.content_length.to_i <= MAX_BODY
        report = begin
          JSON.parse(request.raw_post.to_s)
        rescue JSON::ParserError
          nil
        end
        report = report["csp-report"] if report.is_a?(Hash) && report["csp-report"].is_a?(Hash)
        if report.is_a?(Hash) && (report["violated-directive"].present? || report["effective-directive"].present?)
          reporter.report_csp(report)
        end
      end
      head :no_content
    end
  end
end
