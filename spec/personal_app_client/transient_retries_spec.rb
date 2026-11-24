require "logger"
require "active_job"
require "active_record"
require "personal_app_client/rails/job_status_reporting"
require "personal_app_client/rails/transient_retries"

RSpec.describe PersonalAppClient::Rails::TransientRetries do
  hub = Class.new do
    attr_reader :reports
    def initialize = @reports = []
    def report_job_status(payload) = @reports << payload
  end.new

  flaky_job = Class.new(ActiveJob::Base) do
    include PersonalAppClient::Rails::JobStatusReporting
    include PersonalAppClient::Rails::TransientRetries
    report_job_status name: "flaky sync", via: -> { hub }

    def self.name = "FlakyRetrySpecJob"

    def perform(error_class)
      raise error_class, "blip" if error_class
    end
  end

  before do
    ActiveJob::Base.logger = Logger.new(File::NULL)
    ActiveJob::Base.queue_adapter = :test
    hub.reports.clear
  end

  def enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs

  it "re-enqueues a job that hit a network blip, and reports nothing for that attempt" do
    job = flaky_job.new(PersonalAppClient::ConnectionError)
    expect { job.perform_now }.not_to raise_error
    expect(enqueued.size).to eq(1)
    expect(hub.reports).to be_empty
  end

  it "retries SQLite's database-is-locked (StatementTimeout)" do
    flaky_job.new(ActiveRecord::StatementTimeout).perform_now
    expect(enqueued.size).to eq(1)
  end

  it "gives up after three attempts and reports the failure" do
    job = flaky_job.new(Net::ReadTimeout)
    job.exception_executions = { flaky_job.transient_retry_errors.to_s => 2 }
    expect { job.perform_now }.to raise_error(Net::ReadTimeout)
    expect(hub.reports.map { |r| r[:status] }).to eq([ "fail" ])
  end

  it "does not retry an error that will not pass by itself" do
    job = flaky_job.new(ArgumentError)
    expect { job.perform_now }.to raise_error(ArgumentError)
    expect(enqueued).to be_empty
    expect(hub.reports.map { |r| r[:status] }).to eq([ "fail" ])
  end

  it "reports ok when the job succeeds" do
    flaky_job.new(nil).perform_now
    expect(hub.reports.map { |r| r[:status] }).to eq([ "ok" ])
  end
end
