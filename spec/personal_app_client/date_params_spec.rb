require "personal_app_client/rails/date_params"

class FakeDatesController < FakeActionController
  include PersonalAppClient::Rails::DateParams
end

RSpec.describe PersonalAppClient::Rails::DateParams do
  let(:controller) { FakeDatesController.new }

  def date(value)  = controller.send(:parse_date_param, value)
  def month(value) = controller.send(:parse_month_param, value)

  it "keeps the helpers private so they are not routable actions" do
    expect(FakeDatesController.private_instance_methods).to include(:parse_date_param, :parse_month_param)
  end

  describe "#parse_date_param" do
    it "parses YYYY-MM-DD" do
      expect(date("2026-07-06")).to eq(Date.new(2026, 7, 6))
    end

    it "returns nil for blank, nil and non-strings" do
      expect(date(nil)).to be_nil
      expect(date("")).to be_nil
      expect(date(5)).to be_nil
    end

    it "returns nil for everything Date.parse would guess at" do
      [ "05", "abc-05", "next tuesday", "2026-7-6", "06/07/2026", "2026-07-06T10:00:00",
        " 2026-07-06", "2026-07-06\n2026-07-07" ].each do |value|
        expect(date(value)).to be_nil, "expected #{value.inspect} to be rejected"
      end
    end

    it "returns nil for a well-shaped date that does not exist" do
      expect(date("2026-02-30")).to be_nil
      expect(date("2026-13-01")).to be_nil
    end
  end

  describe "#parse_month_param" do
    it "parses YYYY-MM to the first of the month" do
      expect(month("2026-02")).to eq(Date.new(2026, 2, 1))
    end

    it "returns nil for anything else" do
      [ nil, "", "2026", "2026-13", "2026-00", "2026-2", "2026-02-01", "feb 2026", "abc-05" ].each do |value|
        expect(month(value)).to be_nil, "expected #{value.inspect} to be rejected"
      end
    end
  end

  describe PersonalAppClient::Dates do
    it "exposes the same parsers outside controllers" do
      expect(described_class.parse_date("2026-07-06")).to eq(Date.new(2026, 7, 6))
      expect(described_class.parse_month("2026-07")).to eq(Date.new(2026, 7, 1))
      expect(described_class.parse_date("05")).to be_nil
    end
  end
end
