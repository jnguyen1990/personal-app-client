require "tzinfo"

# Manitoba moved to permanent UTC-5 on 2026-10-31. The hosts' OS zoneinfo
# predates that change (it still says UTC-6 for November), so the apps must
# not read zone data from the OS. TZInfo prefers the bundled Ruby data
# (tzinfo-data, a runtime dependency of this gem) whenever `tzinfo/data` is
# loadable — requiring it here makes that hold no matter how the app's own
# Gemfile scopes tzinfo-data (the Rails default is Windows/JRuby only).
require "tzinfo/data"

module PersonalAppClient
  # The one time zone every personal app runs in:
  #
  #     # config/application.rb
  #     config.time_zone = PersonalAppClient::TIME_ZONE
  TIME_ZONE = "America/Winnipeg".freeze

  # If something resolved a zone before this file loaded, TZInfo may already
  # have settled on the OS zoneinfo directory; switch it to the Ruby data.
  # A no-op in the normal case (data source not chosen yet, or already Ruby).
  def self.ensure_ruby_tzdata!
    return if TZInfo::DataSource.get.is_a?(TZInfo::DataSources::RubyDataSource)
    TZInfo::DataSource.set(:ruby)
  end

  ensure_ruby_tzdata!
end
