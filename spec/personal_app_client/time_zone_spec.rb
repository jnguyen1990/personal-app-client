RSpec.describe "PersonalAppClient::TIME_ZONE" do
  let(:zone) { TZInfo::Timezone.get(PersonalAppClient::TIME_ZONE) }

  def offset_at(time)
    zone.period_for_utc(time).utc_total_offset
  end

  it "is America/Winnipeg" do
    expect(PersonalAppClient::TIME_ZONE).to eq("America/Winnipeg")
  end

  it "reads zone data from the bundled tzinfo-data, not the OS" do
    expect(TZInfo::DataSource.get).to be_a(TZInfo::DataSources::RubyDataSource)
  end

  # Manitoba moved to permanent UTC-5 on 2026-10-31. Zone data older than
  # tzdata 2026f still falls back to UTC-6 on the first Sunday of November.
  it "knows Manitoba stays on UTC-5 after 2026-10-31" do
    expect(offset_at(Time.utc(2026, 11, 5, 18))).to eq(-18_000)
    expect(offset_at(Time.utc(2027, 1, 15, 18))).to eq(-18_000)
  end

  it "still reports the old winter offset before the change" do
    expect(offset_at(Time.utc(2026, 1, 15, 18))).to eq(-21_600)
  end
end
