require "active_record"
require "active_support/rescuable"
require "personal_app_client/rails/api_errors"

# ActionController is not loaded in this suite; the concern names the class
# as a string, so a stand-in with the right name is all it needs.
module ActionController
  class ParameterMissing < KeyError; end unless const_defined?(:ParameterMissing)
end

class FakeApiController < FakeActionController
  include ActiveSupport::Rescuable
  include PersonalAppClient::Rails::ApiErrors

  attr_accessor :to_raise

  def show
    raise to_raise if to_raise
    render(json: { id: 1 })
  end

  # What ActionController::Rescue does around an action.
  def process(action)
    super
  rescue Exception => e # rubocop:disable Lint/RescueException
    rescue_with_handler(e) || raise
    self
  end
end

RSpec.describe PersonalAppClient::Rails::ApiErrors do
  def run(error = nil)
    FakeApiController.new.tap { |c| c.to_raise = error }.process(:show)
  end

  it "leaves a successful action alone" do
    expect(run.rendered).to eq(json: { id: 1 })
  end

  it "renders 404 for ActiveRecord::RecordNotFound" do
    error = ActiveRecord::RecordNotFound.new("Couldn't find Reminder with 'id'=99")
    expect(run(error).rendered).to eq(json: { error: "not found" }, status: :not_found)
  end

  it "renders 400 with the message for ActionController::ParameterMissing" do
    error = ActionController::ParameterMissing.new("param is missing or the value is empty: key")
    expect(run(error).rendered)
      .to eq(json: { error: "param is missing or the value is empty: key" }, status: :bad_request)
  end

  it "lets every other error through" do
    expect { run(ArgumentError.new("boom")) }.to raise_error(ArgumentError, "boom")
  end

  it "yields to a rescue_from the controller declares afterwards" do
    klass = Class.new(FakeApiController) do
      rescue_from(ActiveRecord::RecordNotFound) { render(json: { error: "no such reminder" }, status: 404) }
    end
    c = klass.new
    c.to_raise = ActiveRecord::RecordNotFound.new("x")
    expect(c.process(:show).rendered).to eq(json: { error: "no such reminder" }, status: 404)
  end
end
