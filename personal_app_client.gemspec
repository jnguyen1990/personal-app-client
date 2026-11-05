require_relative "lib/personal_app_client/version"

Gem::Specification.new do |spec|
  spec.name        = "personal_app_client"
  spec.version     = PersonalAppClient::VERSION
  spec.authors     = ["Joe Nguyen"]
  spec.email       = ["joeanguyen1990@gmail.com"]

  spec.summary     = "Shared HTTP client for Joe's personal apps."
  spec.description = "Inter-app HTTP client with loud failures, public-domain guard, " \
                     "and shared-secret auth, plus the Rails concerns the apps share " \
                     "(auth, MCP dispatch, SQLite backup/restore, health, rate limiting). " \
                     "Used by base, budgeter, fitness, mealplanner, postings, and upkeep."
  spec.homepage    = "https://github.com/jnguyen1990/personal-app-client"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_dependency "jwt", ">= 2.7", "< 4"
  spec.add_dependency "rack-attack", ">= 6.6"
  # Manitoba went to permanent UTC-5 on 2026-10-31; 1.2026.6 (tzdata 2026f)
  # is the first release that knows. The hosts' OS zoneinfo does not.
  spec.add_dependency "tzinfo-data", ">= 1.2026.6"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "webrick", "~> 1.8"
  # For SqliteBackup specs (the concern itself only requires these lazily,
  # inside the including app's process).
  spec.add_development_dependency "activerecord", ">= 7.0"
  spec.add_development_dependency "sqlite3", ">= 1.6"
  spec.add_development_dependency "rubyzip", ">= 2.3"
  # For JobStatusReporting specs.
  spec.add_development_dependency "activejob", ">= 7.0"
end
