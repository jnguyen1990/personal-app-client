require "logger"
require "stringio"
require "active_job"
require "personal_app_client/rails/job_status_reporting"

ActiveJob::Base.logger = Logger.new(File::NULL)
ActiveJob::Base.queue_adapter = :inline

module Rails
  def self.logger
    @logger ||= Logger.new(File::NULL)
  end
end

module JobStatusSpec
  # Collects what would have been POSTed to base.
  class Hub
    attr_reader :reports

    def initialize
      @reports = []
    end

    def report_job_status(payload)
      @reports << payload
    end
  end

  HUB = Hub.new

  class BaseJob < ActiveJob::Base
    include PersonalAppClient::Rails::JobStatusReporting
  end

  class NightlyJob < BaseJob
    report_job_status name: "upkeep base sync", cadence: "nightly",
                      schedule: "07:00 America/Winnipeg", expect_within: 26 * 3600,
                      url: "https://upkeep.joenguyen.ca/settings", via: -> { HUB }

    def perform(mode = :ok)
      case mode
      when :ok then :done
      when :detail then job_status(detail: "3 due synced · 1 cleared", log: "full log")
      when :warn then job_status(status: "warn", detail: "2 sources unreadable")
      when :skip then skip_job_status_report!
      when :boom then raise ArgumentError, "x" * 500
      when :boom_after_note
        job_status(log: "got halfway")
        raise "kaput"
      end
    end
  end

  class UntrackedJob < BaseJob
    def perform = :done
  end

  class BrokenHubJob < BaseJob
    report_job_status name: "broken", via: -> { raise IOError, "hub exploded" }

    def perform(fail_job = false)
      raise "job failed" if fail_job
      :done
    end
  end

  class LocalJob < BaseJob
    RECORDED = []
    report_job_status name: "reminder tick", schedule: "every minute", expect_within: 300,
                      via: ->(payload) { RECORDED << payload }

    def perform = :done
  end

  class DefaultHubJob < BaseJob
    report_job_status name: "default hub"

    def perform = :done
  end
end

RSpec.describe PersonalAppClient::Rails::JobStatusReporting do
  let(:hub) { JobStatusSpec::HUB }

  around do |example|
    previous = Time.zone
    Time.zone = "UTC"
    hub.reports.clear
    example.run
    Time.zone = previous
  end

  it "reports ok with the configured fields after a successful run" do
    expect(JobStatusSpec::NightlyJob.perform_now).to eq(:done)

    expect(hub.reports.size).to eq(1)
    report = hub.reports.first
    expect(report).to include(
      name: "upkeep base sync", status: "ok", cadence: "nightly",
      schedule: "07:00 America/Winnipeg", expect_within: 93_600,
      url: "https://upkeep.joenguyen.ca/settings"
    )
    expect(report[:duration_seconds]).to be_a(Integer)
    expect(report).not_to have_key(:detail)
  end

  it "sends only keys base's job-status endpoint accepts" do
    JobStatusSpec::NightlyJob.perform_now(:detail)
    expect(hub.reports.first.keys - PersonalAppClient::HubClient::JOB_STATUS_KEYS).to be_empty
  end

  it "includes the detail and log a job sets with job_status" do
    JobStatusSpec::NightlyJob.perform_now(:detail)
    expect(hub.reports.first).to include(status: "ok", detail: "3 due synced · 1 cleared", log: "full log")
  end

  it "lets a job downgrade a finished run to warn" do
    JobStatusSpec::NightlyJob.perform_now(:warn)
    expect(hub.reports.first).to include(status: "warn", detail: "2 sources unreadable")
  end

  it "reports fail with a truncated message, then re-raises" do
    expect { JobStatusSpec::NightlyJob.perform_now(:boom) }.to raise_error(ArgumentError)

    report = hub.reports.first
    expect(report).to include(name: "upkeep base sync", status: "fail", cadence: "nightly")
    expect(report[:detail].length).to eq(200)
    expect(report[:detail]).to start_with("xxx")
  end

  it "keeps a log noted before the failure" do
    expect { JobStatusSpec::NightlyJob.perform_now(:boom_after_note) }.to raise_error("kaput")
    expect(hub.reports.first).to include(status: "fail", detail: "kaput", log: "got halfway")
  end

  it "reports nothing when the job opts out of this run" do
    expect(JobStatusSpec::NightlyJob.perform_now(:skip)).to be_nil
    expect(hub.reports).to be_empty
  end

  it "does nothing for a job class that never called report_job_status" do
    expect(PersonalAppClient::HubClient).not_to receive(:new)
    expect(JobStatusSpec::UntrackedJob.perform_now).to eq(:done)
    expect(hub.reports).to be_empty
  end

  it "does not leak one job class's settings into a sibling" do
    expect(JobStatusSpec::UntrackedJob.job_status_options).to be_nil
    expect(JobStatusSpec::LocalJob.job_status_options[:name]).to eq("reminder tick")
  end

  describe "when reporting itself fails" do
    it "never breaks a successful job" do
      expect(JobStatusSpec::BrokenHubJob.perform_now).to eq(:done)
    end

    it "never masks the job's own error" do
      expect { JobStatusSpec::BrokenHubJob.perform_now(true) }.to raise_error("job failed")
    end

    it "logs what went wrong" do
      io = StringIO.new
      allow(Rails).to receive(:logger).and_return(Logger.new(io))
      JobStatusSpec::BrokenHubJob.perform_now
      expect(io.string).to include("[job_status] could not report broken: IOError: hub exploded")
    end

    it "survives a payload the hub client rejects" do
      strict = PersonalAppClient::HubClient.new(source_app: "x", env: "production")
      klass = Class.new(JobStatusSpec::BaseJob) do
        def self.name = "RejectedJob"
        report_job_status name: "rejected", via: -> { strict }
        def perform = job_status(message: "not a key base accepts")
      end
      expect { klass.perform_now }.not_to raise_error
    end
  end

  it "hands the payload to a one-argument callable (base recording locally)" do
    JobStatusSpec::LocalJob::RECORDED.clear
    JobStatusSpec::LocalJob.perform_now
    expect(JobStatusSpec::LocalJob::RECORDED.first).to include(
      name: "reminder tick", status: "ok", cadence: "continuous",
      schedule: "every minute", expect_within: 300
    )
  end

  it "reports through HubClient by default" do
    client = instance_double(PersonalAppClient::HubClient, report_job_status: nil)
    allow(PersonalAppClient::HubClient).to receive(:new).and_return(client)
    JobStatusSpec::DefaultHubJob.perform_now
    expect(client).to have_received(:report_job_status)
      .with(hash_including(name: "default hub", status: "ok", cadence: "continuous"))
  end
end
