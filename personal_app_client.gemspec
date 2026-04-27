require_relative "lib/personal_app_client/version"

Gem::Specification.new do |spec|
  spec.name        = "personal_app_client"
  spec.version     = PersonalAppClient::VERSION
  spec.authors     = ["Joe Nguyen"]
  spec.email       = ["joeanguyen1990@gmail.com"]

  spec.summary     = "Shared HTTP client for Joe's personal apps."
  spec.description = "Inter-app HTTP client with loud failures, public-domain guard, " \
                     "and shared-secret auth. Used by base, fitness, and budgeter."
  spec.homepage    = "https://github.com/jnguyen1990/personal-app-client"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "webrick", "~> 1.8"
end
