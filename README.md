# personal_app_client

Shared code for Joe's six personal apps (`base`, `budgeter`, `fitness`,
`mealplanner`, `postings`, `upkeep`): the inter-app HTTP client, and the Rails
concerns the apps would otherwise each carry a private copy of.

```ruby
# Gemfile
gem "personal_app_client", git: "https://github.com/jnguyen1990/personal-app-client.git", tag: "v0.7.0"
```

`require "personal_app_client"` (which Bundler does for you) loads the plain
Ruby core: `Client`, `AppClient`, `HubClient`, the errors, `TIME_ZONE`,
`revision` and `Dates`. Everything else is required explicitly by path, so an
app only loads what it uses.

| Module | Require | What it is |
| --- | --- | --- |
| [`Client`](#client) | `personal_app_client` | HTTP client for inter-app calls |
| [`AppClient`](#appclient) | `personal_app_client` | base class for per-app client wrappers |
| [`HubClient`](#hubclient) | `personal_app_client` | client for base: reminders, job status |
| [`TIME_ZONE`](#time_zone) | `personal_app_client` | the one zone every app runs in |
| [`revision`](#revision) | `personal_app_client` | deployed git SHA |
| [`Dates`](#dateparams-and-dates) | `personal_app_client` | strict date parsing |
| [`CloudflareAccess`](#cloudflareaccess) | `personal_app_client/cloudflare_access` | verify a Cloudflare Access JWT |
| [`RateLimit`](#ratelimit) | `personal_app_client/rate_limit` | one-call Rack::Attack setup |
| [`TestSupport`](#testsupport) | `personal_app_client/test_support` | helpers for the apps' test suites |
| [`Mcp::BaseTool`](#mcpbasetool) | `personal_app_client/mcp/base_tool` | base class for MCP tools |
| [`Mcp::Registry`](#mcpregistry) | `personal_app_client/mcp/registry` | `descriptors` / `find` / `tools` from `TOOLS` |
| [`Rails::InterAppAuth`](#interappauth-and-interappauthoptional) | `personal_app_client/rails/inter_app_auth` | require `X-App-Auth` |
| [`Rails::InterAppAuthOptional`](#interappauth-and-interappauthoptional) | `personal_app_client/rails/inter_app_auth_optional` | check `X-App-Auth` when present |
| [`Rails::ApiKeyAuth`](#apikeyauth) | `personal_app_client/rails/api_key_auth` | shared API key auth |
| [`Rails::OauthResourceServer`](#oauthresourceserver) | `personal_app_client/rails/oauth_resource_server` | OAuth bearer auth for `/api/mcp` |
| [`Rails::OperatorAuth`](#operatorauth) | `personal_app_client/rails/operator_auth` | guard destructive / operator-only actions |
| [`Rails::McpDispatch`](#mcpdispatch) | `personal_app_client/rails/mcp_dispatch` | the MCP JSON-RPC endpoint |
| [`Rails::SqliteBackup`](#sqlitebackup) | `personal_app_client/rails/sqlite_backup` | backup / restore actions |
| [`Rails::HealthCheck`](#healthcheck) | `personal_app_client/rails/health_check` | `/api/health/inter-app` |
| [`Rails::WellKnown`](#wellknown) | `personal_app_client/rails/well_known` | OAuth protected-resource metadata |
| [`Rails::ApiErrors`](#apierrors) | `personal_app_client/rails/api_errors` | JSON 404 / 400 |
| [`Rails::DateParams`](#dateparams-and-dates) | `personal_app_client/rails/date_params` | strict date params in controllers |
| [`Rails::JobStatusReporting`](#jobstatusreporting) | `personal_app_client/rails/job_status_reporting` | report job runs to base |
| [`Rails::SettingStore`](#settingstore) | `personal_app_client/rails/setting_store` | the key/value `Setting` model |

Secrets and environment variables are always read when a method runs, never
when a file loads.

## Client

The apps each had a near-identical `Net::HTTP` wrapper that silently returned
`[]` on non-2xx responses and happily called `https://<app>.joenguyen.ca` URLs
that Cloudflare Access intercepts with a 302 challenge — so when a public URL
ended up in a `Setting` row, inter-app sync broke without a single error log.
`Client` raises on non-2xx (callers decide whether to swallow), refuses to
start in production with a `*.joenguyen.ca` URL, sends the shared secret as
`X-App-Auth`, and retries once on transient network errors.

```ruby
client = PersonalAppClient::Client.new(
  base_url: Setting.get("fitness_app_url"), # e.g. http://fitness.tail5ece07.ts.net:3002
  secret:   ENV["INTER_APP_SECRET"],
  env:      Rails.env,
  logger:   Rails.logger
)

client.get("/api/planned-sessions", start_date: "2026-04-27", end_date: "2026-04-27")
client.post("/api/body-metrics", { recorded_at: Time.now, sleep_hours: 7.5 })
client.put("/api/recipes/3/rate", { rating: 2 })
client.patch("/api/reminders/9", { active: false })
client.delete("/api/reminders/9")
client.last_status # => 200
```

Errors:

- `ConfigurationError` — bad `base_url`, missing host, or production using a
  guarded public domain. Raised at construction.
- `ResponseError` — non-2xx response. Carries `status`, `body`, `url`.
  3xx responses to `cloudflareaccess.com` get a hint in the message.
- `ConnectionError` — connection refused / reset / unreachable after one retry.
- `TimeoutError` — read timeout exceeded.

## AppClient

Base class for the per-app wrappers (`FitnessAppClient`, `MealplannerAppClient`,
`UpkeepAppClient`, …). It builds the `Client` from a `Setting` row and
`INTER_APP_SECRET`, turns a `ConfigurationError` into "unconfigured", and
provides the rescue-and-log shape every wrapper method repeated.

```ruby
class FitnessAppClient < PersonalAppClient::AppClient
  app_client name: "fitness", setting: "fitness_app_url", dev_url: "http://localhost:3000"

  def blocks
    attempt("blocks", default: []) { |http| http.get("/api/blocks") }
  end

  def goals! # raising variant, for explicit user actions
    http!.get("/api/goals")
  end
end

client = FitnessAppClient.new
client.configured? # false when there is no usable URL
client.ping        # { success: true, status: 200, url: "http://…" } — never raises
```

`app_client` options: `name`, `setting` (a key, or an array — first present
wins), `dev_url`, `fallback_envs` (default `development` and `test`),
`force_dev_url` (development always uses `dev_url`), `open_timeout`,
`read_timeout`. **A missing URL means "unconfigured" in production** — `dev_url`
is only ever used in the fallback environments.

`attempt(label, default: nil) { |http| … }` returns `default` when unconfigured
or when the call raises a `PersonalAppClient::Error` (logged). `http!` returns
the `Client` or raises `ConfigurationError`. The client still lives in `@http`,
so methods written against the old hand-rolled shape keep working.

## HubClient

`AppClient` for base, the hub. URL from `Setting` `base_app_url`, else
`self_app_url`, else `http://localhost:3001` in development/test.

```ruby
class BaseAppClient < PersonalAppClient::HubClient
  app_client source_app: "upkeep" # optional; defaults to the Rails app's name
end

client = BaseAppClient.new
client.sync_reminder(source_id: "task-7", title: "Bike: chain", description: "due in 3 days")
client.delete_reminder("task-7")
client.report_job_status(name: "upkeep base sync", status: "ok", cadence: "nightly")
client.ping
```

All three return base's JSON, or `nil` when unconfigured or the call failed
(logged). Payload keys are checked against what base's controllers permit
(`HubClient::REMINDER_KEYS`, `HubClient::JOB_STATUS_KEYS`): base silently drops
anything else, so an unknown key raises `ArgumentError` here instead.

## TIME_ZONE

```ruby
# config/application.rb
config.time_zone = PersonalAppClient::TIME_ZONE # "America/Winnipeg"
```

Manitoba moved to permanent UTC−5 on 2026-10-31 and the hosts' OS zone data
predates that. The gem depends on `tzinfo-data >= 1.2026.6` and requires it, so
TZInfo uses the bundled data instead of the OS's.

## revision

```ruby
PersonalAppClient.revision # => "a269fce61e4a…" or nil
```

The deployed git SHA: a `REVISION` file at `Rails.root` if present, else
`.git/HEAD` followed to its ref (or `packed-refs`). Plain file reads, no
subprocess; memoized for the life of the process.

## DateParams and Dates

`Date.parse` reads `"05"` as the 5th of the current month and `"next tuesday"`
as a real date. These accept exactly `YYYY-MM-DD` / `YYYY-MM`, check the date
exists, and return `nil` otherwise.

```ruby
require "personal_app_client/rails/date_params"

class ApplicationController < ActionController::Base
  include PersonalAppClient::Rails::DateParams
end

parse_date_param(params[:date])   # => Date or nil
parse_month_param(params[:month]) # => first-of-month Date or nil

PersonalAppClient::Dates.parse_date("2026-02-30") # => nil (outside controllers)
```

## CloudflareAccess

```ruby
require "personal_app_client/cloudflare_access"

claims = PersonalAppClient::CloudflareAccess.verify(request.headers["Cf-Access-Jwt-Assertion"])
claims && claims["email"]
```

Returns the claims of a valid RS256 token (signature against the team's JWKS,
issuer, expiry) or `nil`; never raises. `CF_ACCESS_TEAM_DOMAIN` sets the team
(default `jnguyen.cloudflareaccess.com`); if `CF_ACCESS_AUD` is set it must
appear in `aud`. Keys are cached for five minutes and stale keys are reused if
a refresh fails (`PersonalAppClient::JwksCache`, shared with
`OauthResourceServer`). Never trust `Cf-Access-Authenticated-User-Email` on its
own — any tailnet device can send it.

## RateLimit

```ruby
# config/initializers/rack_attack.rb
require "personal_app_client/rate_limit"

PersonalAppClient::RateLimit.install!
```

120 requests a minute per IP on `/api/`, answered with a JSON 429 and
`Retry-After`. A block adds app-specific rules:

```ruby
PersonalAppClient::RateLimit.install! do |attack|
  attack.throttle("icloud-bridge/ip", limit: 60, period: 60) do |req|
    req.ip if req.path.start_with?("/api/icloud-bridge/")
  end
end
```

Options: `limit:`, `period:`, `path_prefix:`, `api_throttle: false` (block rules
only). `rack-attack` is a dependency of the gem; the middleware is inserted once
however often this runs.

## TestSupport

```ruby
# test/test_helper.rb
require "personal_app_client/test_support"

PersonalAppClient::TestSupport.block_network! # WebMock net block, if WebMock is loaded

class ActionDispatch::IntegrationTest
  include PersonalAppClient::TestSupport
end
```

Provides `json_headers`, `inter_app_headers` (`json: true` adds the JSON content
type), `mcp_headers`, `mcp_call(method, params = {})` and
`mcp_tool_result(body)`. Works with Minitest; depends on neither it nor Rails.

## Mcp::BaseTool

```ruby
require "personal_app_client/mcp/base_tool"

module Mcp
  BaseTool = PersonalAppClient::Mcp::BaseTool # or subclass it to add helpers
end
```

Tools override `tool_name`, `description`, `input_schema` and `call(args)`.
Helpers: `parse_date(value, default: nil)` and `parse_date_arg!(args, key)`
(strict `YYYY-MM-DD`, `ArgumentError` otherwise), `parse_time(value)`,
`clamp_int(value, default:, min: 1, max: 100)`.

## Mcp::Registry

```ruby
require "personal_app_client/mcp/registry"

module Mcp
  module ToolRegistry
    extend PersonalAppClient::Mcp::Registry

    TOOLS = [ Tools::ListItems, Tools::GetItem ].freeze
  end
end
```

Gives `tools`, `descriptors`, `find(name)` and `tool_names` — the interface
`McpDispatch` calls.

## InterAppAuth and InterAppAuthOptional

```ruby
# Strict — always require X-App-Auth. For routes ONLY called by sibling apps.
require "personal_app_client/rails/inter_app_auth"

class Api::SyncController < ApplicationController
  include PersonalAppClient::Rails::InterAppAuth
end

# Optional — header absent → pass (browser path); header present → must match.
require "personal_app_client/rails/inter_app_auth_optional"

class Api::BaseController < ApplicationController
  include PersonalAppClient::Rails::InterAppAuthOptional
end
```

Strict reads `ENV["INTER_APP_SECRET"]`, 503 if unset, 401 on mismatch. Optional
503s only when the header *is* present but the server has no secret.

## ApiKeyAuth

```ruby
require "personal_app_client/rails/api_key_auth"

class Api::IcloudBridgeController < ApplicationController
  include PersonalAppClient::Rails::ApiKeyAuth
  api_key_config env: "BRIDGE_API_KEY", credential: [ :bridge, :api_key ]
end
```

Shared-key auth via `X-API-Key` or `Authorization: Bearer`, constant-time
compare. Defaults to `ENV["MCP_API_KEY"]` / `credentials.mcp.api_key`; 503 when
no key is configured.

## OauthResourceServer

```ruby
require "personal_app_client/rails/oauth_resource_server"

class Api::McpController < BaseController
  include PersonalAppClient::Rails::OauthResourceServer
end
```

Makes the controller an OAuth 2.1 resource server for claude.ai's connector
flow: accepts an RS256 bearer JWT issued by base and audience-bound to this app,
or the legacy shared key. Reads `MCP_OAUTH_ISSUER`, `MCP_OAUTH_JWKS_URL`,
`MCP_RESOURCE_URL`, `MCP_PR_METADATA_URL`, `MCP_API_KEY` (override the names
with `oauth_rs_config`). On failure: 401 with a `WWW-Authenticate` header
pointing at the protected-resource metadata. Exposes `current_mcp_subject`.

## OperatorAuth

```ruby
require "personal_app_client/rails/operator_auth"

class Api::SettingsController < BaseController
  include PersonalAppClient::Rails::OperatorAuth
  operator_auth only: [ :wipe_data ] # omit to guard every action
end
```

For actions that must never run for an anonymous tailnet device. A request
passes with **either** `X-App-Auth` matching `INTER_APP_SECRET` (machine
callers) **or** a valid Cloudflare Access JWT — the `Cf-Access-Jwt-Assertion`
header, else the `CF_Authorization` cookie — verified by `CloudflareAccess`.
Otherwise 401 `{"error":"unauthorized"}`. `current_operator` is `:inter_app` or
the Access identity.

Enforced only in production. `operator_auth enforce: true` (or `false`) pins it
per controller; `OPERATOR_AUTH_ENFORCE=1` turns it on everywhere and cannot turn
it off.

## McpDispatch

```ruby
require "personal_app_client/rails/mcp_dispatch"

class Api::McpController < BaseController
  include PersonalAppClient::Rails::McpDispatch
  include PersonalAppClient::Rails::OauthResourceServer

  mcp_config server_name: "base-mcp", tool_registry: "Mcp::ToolRegistry"
end

# config/routes.rb
post "mcp", to: "mcp#handle"
```

The MCP Streamable HTTP endpoint (JSON-RPC 2.0): `initialize`, `tools/list`,
`tools/call`, `ping`. `tool_registry` is a module, a String (constantized per
request) or a Proc. Authentication is not included — compose with
`OauthResourceServer` or `ApiKeyAuth`.

## SqliteBackup

```ruby
require "personal_app_client/rails/sqlite_backup"

class Api::BackupsController < BaseController
  include PersonalAppClient::Rails::SqliteBackup

  sqlite_backup_config prefix: "fitness",
                       extra_files: %w[CLAUDE.md README.md],
                       include_storage: true
end
```

Actions: `create_backup`, `download`, `list`, `prune`, `restore`,
`restore_upload`. Backups are ZIPs in `tmp/` (the newest `keep`, default 3, are
retained).

Restore replaces the contents of **every table present in both the backup and
the live database** — except `sqlite_%`, `ar_internal_%`, `schema_migrations`
and anything in `exclude_tables:` — copying the columns the two share. Foreign
keys are off during the copy, so no ordering is needed; `tables_delete_order:`
is still accepted as a hint. Override `restore_database(temp_db_path, zip_path)`
for bespoke mapping.

Other options: `keep`, `db_entry_name`, `wal_checkpoint` (default `true`),
`list_include_size`, `source_db_path`.

The concern includes [`OperatorAuth`](#operatorauth): **in production every
backup action needs `X-App-Auth` or a Cloudflare Access JWT.**

## HealthCheck

```ruby
require "personal_app_client/rails/health_check"

class Api::HealthController < BaseController
  include PersonalAppClient::Rails::HealthCheck

  private

  def health_targets # default: []
    [ probe_client("base", BaseAppClient.new),
      probe("weather", url) { WeatherApi.fetch! } ]
  end
end

# config/routes.rb
get "health/inter-app", to: "health#inter_app"
```

`inter_app` renders `{ ok:, checked_at:, revision:, targets: [] }`. Helpers:
`probe(name, url) { … }` (ok with latency, or error), `unconfigured(name, url)`,
`probe_client(name, app_client, path = "/up")`, and `health_payload(targets)`
for controllers that render the shape themselves.

## WellKnown

```ruby
require "personal_app_client/rails/well_known"

class WellKnownController < ActionController::API
  include PersonalAppClient::Rails::WellKnown
end

# config/routes.rb
get "/.well-known/oauth-protected-resource", to: "well_known#protected_resource"
```

RFC 9728 metadata pointing MCP clients at base as the authorization server.
Reads `MCP_OAUTH_ISSUER` (default `https://base.joenguyen.ca`) and
`MCP_RESOURCE_URL` (default `<request base URL>/api/mcp`).

## ApiErrors

```ruby
require "personal_app_client/rails/api_errors"

class Api::BaseController < ApplicationController
  include PersonalAppClient::Rails::ApiErrors
end
```

`ActiveRecord::RecordNotFound` → 404 `{"error":"not found"}`;
`ActionController::ParameterMissing` → 400 `{"error":"<message>"}`.

## JobStatusReporting

```ruby
require "personal_app_client/rails/job_status_reporting"

class ApplicationJob < ActiveJob::Base
  include PersonalAppClient::Rails::JobStatusReporting
end

class SyncDueToBaseJob < ApplicationJob
  report_job_status name: "upkeep base sync", cadence: "nightly",
                    schedule: "07:00 America/Winnipeg", expect_within: 26.hours

  def perform
    return skip_job_status_report! unless Setting.bool("base_sync_enabled")
    # …
    job_status detail: "#{synced} due synced · #{cleared} cleared"
  end
end
```

Reports `ok` when `perform` returns and `fail` (with the error message) when it
raises, then re-raises. A failure to deliver the report is logged and dropped —
it never breaks the job. Reports go through `HubClient#report_job_status`;
`via:` takes a callable returning another client (`via: -> { BaseAppClient.new }`)
or one taking the payload (`via: ->(payload) { JobStatus.record!(**payload) }`,
for base itself). Jobs that never call `report_job_status` are untouched.

## SettingStore

```ruby
require "personal_app_client/rails/setting_store"

class Setting < ApplicationRecord
  include PersonalAppClient::Rails::SettingStore

  DEFAULTS = { "lead_days" => "14" }.freeze # optional
end
```

`get(key, default = nil)`, `set(key, value)`, `bulk_update(hash)`, `int(key)`,
`bool(key)` (lenient: `true`/`1`/`on`/`yes`) and `get_bool(key)` (strict:
exactly `"true"`), plus the `key` presence/uniqueness validation. `set` returns
the stored value; `self.setting_set_returns = :record` returns the record.

## Local dev

```sh
bundle install
bundle exec rspec
```

Releases are git tags; see [CHANGELOG.md](CHANGELOG.md).
