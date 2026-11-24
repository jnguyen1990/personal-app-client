require "json"

module PersonalAppClient
  # The one list of apps (PLAT-44), from apps.json beside this file:
  #
  #     PersonalAppClient.apps                 # => [App(id: "base", …), …]
  #     PersonalAppClient.app("fitness").tailnet_url
  #     PersonalAppClient::Apps.mcp_resources  # base's OAuth audience
  #
  # Before this the list was hard-coded in the launcher, base's apps.yml and
  # OAuth audience, and four mini scripts; past additions missed some.
  module Apps
    FIELDS = %i[id name dock_name accent description public_url tailnet_url dev_url mcp_resource repo ctid icon].freeze
    App = Struct.new(*FIELDS, keyword_init: true)
    PATH = File.expand_path("apps.json", __dir__)

    module_function

    def all
      @all ||= JSON.parse(File.read(PATH, encoding: "UTF-8"))["apps"].map { |a| App.new(**a.transform_keys(&:to_sym).slice(*FIELDS)) }.freeze
    end

    def find(id)
      all.find { |a| a.id == id.to_s }
    end

    def mcp_resources
      all.map(&:mcp_resource).compact
    end

    # What the launcher dock needs (window.PERSONAL_APPS).
    def for_launcher
      all.map { |a| { id: a.id, name: a.name, dock_name: a.dock_name, public_url: a.public_url } }
    end
  end
end
