require "personal_app_client/apps"

RSpec.describe PersonalAppClient::Apps do
  it "lists the six apps with every field the consumers read" do
    ids = described_class.all.map(&:id)
    expect(ids).to eq(%w[base budgeter fitness mealplanner upkeep postings])
    described_class.all.each do |a|
      expect(a.public_url).to eq("https://#{a.id}.joenguyen.ca")
      expect(a.tailnet_url).to eq("http://#{a.id}.tail5ece07.ts.net:3000")
      expect(a.mcp_resource).to eq("#{a.public_url}/api/mcp")
      expect([ a.name, a.dock_name, a.accent, a.repo, a.ctid ]).to all(be_present)
    end
  end

  it "gives base its OAuth audience and the launcher its dock" do
    expect(described_class.mcp_resources.size).to eq(6)
    expect(described_class.for_launcher.find { |a| a[:id] == "mealplanner" }[:dock_name]).to eq("Meals")
    expect(PersonalAppClient.app("upkeep").ctid).to eq(110)
  end
end
