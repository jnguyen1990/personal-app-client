require "active_support/concern"
require "active_support/core_ext/class/attribute"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/time/calculations"
require "active_support/core_ext/time/zones"
require_relative "../hub_client"

module PersonalAppClient
  module Rails
    # ActiveJob concern: report every run of a job — success AND failure — to
    # base's /jobs page. Opt in per job class:
    #
    #     class ApplicationJob < ActiveJob::Base
    #       include PersonalAppClient::Rails::JobStatusReporting
    #     end
    #
    #     class SyncDueToBaseJob < ApplicationJob
    #       report_job_status name: "upkeep base sync", cadence: "nightly",
    #                         schedule: "07:00 America/Winnipeg", expect_within: 26.hours
    #
    #       def perform
    #         return skip_job_status_report! unless Setting.bool("base_sync_enabled")
    #         …
    #         job_status detail: "#{synced} due synced · #{cleared} cleared"
    #       end
    #     end
    #
    # A run that returns reports "ok"; one that raises reports "fail" with the
    # error message, then re-raises so retries / error tracking are unchanged.
    # The report itself can never break the job: any failure to deliver it is
    # logged and dropped.
    #
    # `report_job_status` options: name (required), cadence ("continuous" /
    # "nightly" / "weekly"), schedule, expect_within (seconds), url — the
    # fields base's Api::JobStatusesController accepts — plus:
    #   via   where reports go. Default: PersonalAppClient::HubClient.new.
    #         Pass a callable returning a client (`via: -> { BaseAppClient.new }`)
    #         or, on base itself, one taking the payload
    #         (`via: ->(payload) { JobStatus.record!(**payload) }`).
    module JobStatusReporting
      extend ActiveSupport::Concern

      DETAIL_LIMIT = 200

      included do
        class_attribute :job_status_options, instance_writer: false, default: nil

        around_perform do |job, block|
          job.send(:run_with_job_status_report, &block)
        end
      end

      class_methods do
        def report_job_status(name:, cadence: "continuous", schedule: nil,
                              expect_within: nil, url: nil, via: nil)
          self.job_status_options = {
            name: name, cadence: cadence, schedule: schedule,
            expect_within: expect_within&.to_i, url: url, via: via
          }.freeze
        end
      end

      # Call from `perform` to shape the success report: a `detail` line, a
      # `log`, a softer `status` ("warn"), or a `url`. Returns nil.
      def job_status(**fields)
        (@job_status_fields ||= {}).merge!(fields)
        nil
      end

      # Call from `perform` when this run should not be reported at all (the
      # feature is switched off, nothing was attempted). Returns nil.
      def skip_job_status_report!
        @job_status_skipped = true
        nil
      end

      private

      def run_with_job_status_report
        options = self.class.job_status_options
        return yield unless options

        started = Time.current
        begin
          result = yield
        rescue => e
          deliver_job_status(options, started,
                             (@job_status_fields || {}).merge(
                               status: "fail", detail: e.message.to_s.truncate(DETAIL_LIMIT)
                             ))
          raise
        end
        deliver_job_status(options, started, { status: "ok" }.merge(@job_status_fields || {}))
        result
      end

      def deliver_job_status(options, started, fields)
        return if @job_status_skipped

        payload = {
          name: options[:name], cadence: options[:cadence], schedule: options[:schedule],
          duration_seconds: (Time.current - started).round,
          expect_within: options[:expect_within], url: options[:url]
        }.merge(fields).compact

        via = options[:via]
        if via.respond_to?(:call) && via.arity == 1
          via.call(payload)
        else
          client = via.respond_to?(:call) ? via.call : PersonalAppClient::HubClient.new
          client.report_job_status(payload)
        end
      rescue => e
        # Reporting is best-effort. Never let it fail (or mask the failure of)
        # the job it is reporting on.
        job_status_logger&.warn("[job_status] could not report #{options[:name]}: #{e.class}: #{e.message}")
        nil
      end

      def job_status_logger
        defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
      end
    end
  end
end
