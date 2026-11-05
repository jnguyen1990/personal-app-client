require "active_record"
require "personal_app_client/rails/setting_store"

RSpec.describe PersonalAppClient::Rails::SettingStore do
  # Anonymous models over one in-memory table; `name` is what the uniqueness
  # validation and error messages need.
  def model(defaults: nil, &block)
    Class.new(ActiveRecord::Base) do
      self.table_name = "settings"
      def self.name = "Setting"
      const_set(:DEFAULTS, defaults.freeze) if defaults
      include PersonalAppClient::Rails::SettingStore
      class_eval(&block) if block
    end
  end

  before do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.connection.execute(
      "CREATE TABLE settings (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, value TEXT, " \
      "created_at DATETIME, updated_at DATETIME)"
    )
  end

  after { ActiveRecord::Base.connection_pool.disconnect! }

  let(:setting) { model(defaults: { "lead_days" => "14", "base_sync_enabled" => "1" }) }

  describe ".get" do
    it "returns the stored value" do
      setting.set("lead_days", 21)
      expect(setting.get("lead_days")).to eq("21")
    end

    it "falls back to DEFAULTS, then the given default, then nil" do
      expect(setting.get("lead_days")).to eq("14")
      expect(setting.get("missing", "fallback")).to eq("fallback")
      expect(setting.get("missing")).to be_nil
    end

    it "works on a model with no DEFAULTS constant" do
      plain = model
      expect(plain.get("anything")).to be_nil
      expect(plain.get("anything", "d")).to eq("d")
    end

    it "prefers a stored empty string over the default" do
      setting.set("lead_days", "")
      expect(setting.get("lead_days")).to eq("")
    end
  end

  describe ".set" do
    it "upserts, storing the value as a string" do
      setting.set("k", 1)
      setting.set("k", true)
      expect(setting.where(key: "k").pluck(:value)).to eq([ "true" ])
    end

    it "returns the stored value by default" do
      expect(setting.set("k", 5)).to eq("5")
    end

    it "returns the record when setting_set_returns is :record" do
      record_style = model { self.setting_set_returns = :record }
      result = record_style.set("k", 5)
      expect(result).to be_a(record_style)
      expect(result.value).to eq("5")
    end
  end

  it ".bulk_update sets every pair" do
    setting.bulk_update("a" => 1, "b" => "two")
    expect(setting.get("a")).to eq("1")
    expect(setting.get("b")).to eq("two")
  end

  it ".int reads an integer (0 when unset)" do
    expect(setting.int("lead_days")).to eq(14)
    expect(setting.int("missing")).to eq(0)
  end

  it ".bool is lenient about what counts as true" do
    expect(setting.bool("base_sync_enabled")).to be(true) # "1" from DEFAULTS
    %w[true TRUE on Yes 1].each { |v| setting.set("flag", v); expect(setting.bool("flag")).to be(true) }
    [ "false", "0", "off", "", "2" ].each { |v| setting.set("flag", v); expect(setting.bool("flag")).to be(false) }
    expect(setting.bool("missing")).to be(false)
  end

  it ".get_bool is strict: exactly \"true\"" do
    setting.set("flag", "true")
    expect(setting.get_bool("flag")).to be(true)
    %w[1 on TRUE yes false].each { |v| setting.set("flag", v); expect(setting.get_bool("flag")).to be(false) }
    expect(setting.get_bool("missing")).to be(false)
  end

  it "validates key presence and uniqueness" do
    setting.create!(key: "k", value: "v")
    expect(setting.new(key: "k", value: "other")).not_to be_valid
    expect(setting.new(key: nil, value: "v")).not_to be_valid
  end
end
