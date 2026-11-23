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
  end
end
