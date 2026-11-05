require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/module/introspection"
require_relative "app_client"

module PersonalAppClient
  # Client for base, the hub: reminders (base owns delivery) and the /jobs
  # status page. Replaces the hand-copied BaseAppClient in the spoke apps.
  #
  #     class BaseAppClient < PersonalAppClient::HubClient
  #       app_client source_app: "upkeep"   # optional — see #source_app
  #     end
  #
  #     client = BaseAppClient.new
  #     client.sync_reminder(source_id: "task-7", title: "Bike: chain", description: "…")
  #     client.delete_reminder("task-7")
  #     client.report_job_status(name: "upkeep base sync", status: "ok", cadence: "nightly")
  #
  # The URL comes from Setting "base_app_url", else "self_app_url" (the two
  # keys the apps use today), else http://localhost:3001 in development/test.
  #
  # Payload keys are checked against what base's controllers actually permit.
  # base silently drops anything else, which is how fitness came to send
  # `external_id` / `notes` for months without either being stored — so an
  # unknown key raises ArgumentError here instead of vanishing there.
  class HubClient < AppClient
    app_client name: "base", setting: %w[base_app_url self_app_url],
               dev_url: "http://localhost:3001"

    # Api::RemindersController#sync — find_sync_target + sync_attributes,
    # plus the two nested collections it saves.
    REMINDER_KEYS = %i[
      id source_id title description message kind goal_id block_id
      starts_on ends_on requires_completion active steps notifications
    ].freeze

    # Api::JobStatusesController#upsert.
    JOB_STATUS_KEYS = %i[
      name status detail cadence schedule ran_at duration_seconds
      expect_within url log
    ].freeze

    # Idempotent upsert keyed on (source_app, source_id). Returns base's
    # reminder JSON, or nil when unconfigured or the call failed (logged).
    def sync_reminder(payload)
      payload = checked_payload(payload, REMINDER_KEYS, "reminder")
      unless payload.key?(:source_id) || payload.key?(:id)
        raise ArgumentError, "reminder payload needs source_id (or id)"
      end
      attempt("sync_reminder") do |http|
        http.post("/api/reminders/sync", payload.merge(source_app: source_app))
      end
    end

    # Drop the reminder this app mirrored under `source_id`. A reminder that
    # is already gone is a success on base's side.
    def delete_reminder(source_id)
      attempt("delete_reminder") do |http|
        http.post("/api/reminders/sync",
                  { action_type: "delete", source_app: source_app, source_id: source_id })
      end
    end

    # Self-report one job run onto base's /jobs page (fire-and-forget).
    # `name` and `status` ("ok" / "warn" / "fail") are required.
    def report_job_status(payload)
      payload = checked_payload(payload, JOB_STATUS_KEYS, "job status")
      %i[name status].each do |key|
        raise ArgumentError, "job status payload needs #{key}" if payload[key].blank?
      end
      attempt("report_job_status") { |http| http.post("/api/job-statuses/sync", payload) }
    end

    # The (source_app, …) half of the reminder key. Defaults to the Rails
    # application's name ("Upkeep::Application" → "upkeep"); set it with
    # `app_client source_app: "…"` or HubClient.new(source_app: "…").
    def source_app
      @source_app ||= (self.class.app_client_options[:source_app] || default_source_app).to_s
    end

    def initialize(source_app: nil, **options)
      @source_app = source_app&.to_s
      super(**options)
    end

    private

    def default_source_app
      app = defined?(::Rails) && ::Rails.respond_to?(:application) ? ::Rails.application : nil
      name = app && app.class.respond_to?(:module_parent_name) ? app.class.module_parent_name : nil
      if name.blank?
        raise PersonalAppClient::ConfigurationError,
              "HubClient needs a source_app (app_client source_app: \"…\")"
      end
      name.underscore
    end

    def checked_payload(payload, allowed, what)
      payload = payload.to_h.transform_keys(&:to_sym)
      unknown = payload.keys - allowed
      return payload if unknown.empty?
      raise ArgumentError,
            "unknown #{what} key(s) #{unknown.join(', ')} — base accepts #{allowed.join(', ')}"
    end
  end
end
