require "personal_app_client/rails/well_known"

class FakeWellKnownController < FakeActionController
  include PersonalAppClient::Rails::WellKnown
end

RSpec.describe PersonalAppClient::Rails::WellKnown do
  around do |example|
    saved = ENV.to_h.slice("MCP_OAUTH_ISSUER", "MCP_RESOURCE_URL")
    ENV.delete("MCP_OAUTH_ISSUER")
    ENV.delete("MCP_RESOURCE_URL")
    example.run
  ensure
    ENV.delete("MCP_OAUTH_ISSUER")
    ENV.delete("MCP_RESOURCE_URL")
    saved.each { |k, v| ENV[k] = v }
  end

  def metadata
    FakeWellKnownController.new.process(:protected_resource).rendered[:json]
  end

  it "serves RFC 9728 metadata with the cluster defaults" do
    expect(metadata).to eq(
      resource: "https://app.example.test/api/mcp",
      authorization_servers: [ "https://base.joenguyen.ca" ],
      scopes_supported: [ "mcp" ],
      bearer_methods_supported: [ "header" ]
    )
  end

  it "reads the issuer and resource from the environment per request" do
    ENV["MCP_OAUTH_ISSUER"] = "https://as.example.test"
    ENV["MCP_RESOURCE_URL"] = "https://upkeep.joenguyen.ca/api/mcp"
    expect(metadata).to include(
      resource: "https://upkeep.joenguyen.ca/api/mcp",
      authorization_servers: [ "https://as.example.test" ]
    )
  end

  it "treats blank environment values as unset" do
    ENV["MCP_OAUTH_ISSUER"] = ""
    ENV["MCP_RESOURCE_URL"] = " "
    expect(metadata).to include(resource: "https://app.example.test/api/mcp",
                                authorization_servers: [ "https://base.joenguyen.ca" ])
  end
end
