# personal_app_client

Shared code for Joe's six personal apps (`base`, `budgeter`, `fitness`,
`mealplanner`, `postings`, `upkeep`): the inter-app HTTP client, the Rails
concerns the apps would otherwise each carry a private copy of, and (since
v0.8.0) a Rails engine with the platform routes, default controllers, the
shared layout shell, settings panes, PWA and error reporting.

```ruby
# Gemfile
gem "personal_app_client", git: "https://github.com/jnguyen1990/personal-app-client.git", tag: "v0.10.4"
```

`require "personal_app_client"` (which Bundler does for you) loads the plain
Ruby core: `Client`, `AppClient`, `HubClient`, the errors, `TIME_ZONE`,
`revision`, `Dates` and the engine configuration. Everything else autoloads on
first reference (v0.8.0+), so the `require "personal_app_client/…"` lines
below are optional; they keep working. Inside a Rails app the
[engine](#the-engine-v080) loads too.

| Module | Require (optional since v0.8.0) | What it is |
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
| [`Engine`](#the-engine-v080) | loaded inside Rails | routes macro, default controllers, shell, panes, PWA, Railtie |
| [`configure` / `config`](#configure) | `personal_app_client` | the engine's per-app settings |
| [`ErrorReporting`](#error-reporting) | `personal_app_client/error_reporting` | deduplicated error events to base |
| [`DsSnapshot`](#design-system-fallback) | `personal_app_client/ds_snapshot` | copy the design system into `public/ds/` |

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
client.report_error(fingerprint: "3f2a…", error_class: "NoMethodError", count: 1) # v0.8.0, see Error reporting
client.ping
```

All three return base's JSON, or `nil` when unconfigured or the call failed
(logged). Payload keys are checked against what base's controllers permit
(`HubClient::REMINDER_KEYS`, `HubClient::JOB_STATUS_KEYS`, `HubClient::ERROR_EVENT_KEYS`): base silently drops
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

On the engine this call is made for you (`config.rate_limit`); the
initializer below is the pre-v0.8.0 shape.

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

What a restore writes (v0.8.0): the database, and with `include_storage` the
`storage_files/` entries — only regular files whose path resolves inside
`storage/` (no absolute names, no `..`, no symlinks, never a `.sqlite3` file);
unsafe entries are skipped and logged. `extra_files` (CLAUDE.md, README.md)
are zipped for reference and **not** written back — they are tracked repo
files. An uploaded ZIP gets the same checks.

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

## The engine (v0.8.0)

Loaded automatically inside a Rails app (it needs Rails >= 7.1). It is not an
isolated engine: nothing is mounted, its routes are drawn into the app by a
macro, and its views sit behind the app's, so **an app overrides any engine
partial by putting a file at the same path under `app/views/`.**

### Configure

One initializer per app, `config/initializers/personal_app.rb`:

```ruby
PersonalAppClient.configure do |app|
  app.app_id = "upkeep"                      # data-app, <title> suffix, default <h1>
  app.nav_items = [
    { path: "/",         label: "garage",   ico: "wrench",  key: "1", prefixes: %w[/items] },
    { path: "/due",      label: "due",      ico: "clock",   key: "2" },
    { path: "/settings", label: "settings", ico: "sliders", key: "," }
  ]
  app.health_targets = -> { [ probe_client("base", BaseAppClient.new) ] }
end
```

| Key | Default | What it does |
| --- | --- | --- |
| `app_id` | the Rails app's module name, underscored | `data-app`, `<title>` suffix, default `<h1>`, MCP server name, backup prefix |
| `app_name` | `app_id.capitalize` | sidebar brand, PWA name |
| `nav_items` | `[]` | sidebar items: `path`, `label`, `ico`, `key`, optional `active:` (`:exact` default, `:prefix`, Regexp, Proc of the path) and `prefixes:` (extra prefixes that also mark it active), and `tab:` (`true` to pick it for the mobile tab bar, `false` to keep it out of the default first four). Or a Proc returning the array, run in the view |
| `ds_scripts` | `[]` | extra design-system scripts between `shared-core.js` and `modal-keys.js` (base, fitness: `%w[session-render goal-render]`) |
| `header_style` | `:inline` | `:inline` (title, badge, actions on one row; subtitle under it) or `:split` (title over subtitle on the left, actions right — base) |
| `subtitle_tag` | `:p` | `:span` reproduces upkeep's and postings' subtitle |
| `nav_hotkeys` | `true` | emit `installNavHotkeys({ allowComma: true })` before `:extra_js` |
| `tab_bar` | `true` | below 768px (design system v4.4) render the nav as a floating tab bar plus a "More" bottom sheet (the other items and the app dock) instead of the hamburger + drawer. `false` keeps the hamburger |
| `tab_count` | `4` | how many tabs (1–5) beside "More": the `tab: true` items when any are marked, else the first `tab_count` not marked `tab: false` |
| `ds_base` | `ENV["DS_BASE"]`, else `https://design-system.joenguyen.ca` | where the design system is loaded from (String or Proc) |
| `ds_fallback` | `true` | when `public/ds/` exists, every design-system tag falls back to it if the CDN fails |
| `ds_release` | the release this gem ships (`ds_release.json`); `false` with `ENV["DS_BASE"]` | the design-system release the shell loads — the design system's `v/<sha>/manifest.json` as a Hash (`sha`, `files` → sha384). Each file loads from `<ds_base>/v/<sha>/<file>` with `integrity` + `crossorigin`; `false` = the unversioned always-latest URLs. See "Pinned design system" |
| `palette` | `true` | ⌘K palette: meta tag, sidebar/More-sheet search control. Apps add actions with `dsCommands.register`. |
| `search` | `nil` | `->(q, limit:) { [...] }` — this app's records for `GET /api/search` (route group `search:`); nil = no results |
| `app_stylesheet` | `true` | Link `apps/<app_id>.css` after `design-system.css` (pinned, SRI, snapshot). |
| `narrow_pages` | settings, `/new`, `/edit` | Pages rendered in the ~720px column; per page: `content_for :content_width, "narrow" \| "wide"`. |
| `content_security_policy` | `:report_only` | `:enforce`, `:report_only` or `false`. See "Content security policy". An app's own `config/initializers/content_security_policy.rb` policy always wins |
| `content_security_policy_extra` | `nil` | Proc receiving the policy after the defaults, to add a source |
| `api_base_controller` | `"Api::BaseController"` | parent of the default MCP / backup / health / client-error controllers (falls back to `PersonalAppClient::ApiController` when the app has none) |
| `mcp_server_name` | `"<app_id>-mcp"` | MCP `serverInfo.name` |
| `mcp_tool_registry` | `"Mcp::ToolRegistry"` | registry for the default MCP controller and the connector pane |
| `backup` | `{}` | `sqlite_backup_config` options, merged over `prefix: app_id, extra_files: %w[CLAUDE.md README.md]` |
| `health_targets` | `nil` (no targets) | Proc run in the health controller; may call `probe_client` / `probe` / `unconfigured` |
| `rate_limit` | `{}` | `RateLimit.install!` options (`limit:`, `period:`, …), or `false` to leave it to the app |
| `rate_limit_rules` | `nil` | Proc receiving `Rack::Attack` for app throttles |
| `pwa.service_worker` | production only | `true`, `false`, or `:unregister` (kill switch: serves a self-removing worker and unregisters from the page) |
| `pwa.theme_colors` | `{ light: "#ffffff", dark: "#111113" }` | `<meta name="theme-color">` per scheme (the page `--sheet` of the flat v4.4 surface model); light is the manifest colour |
| `pwa.short_name`, `pwa.description` | `app_name` | manifest fields |
| `pwa.cache_origins` | Google Fonts, jsDelivr, unpkg | origins the worker serves stale-while-revalidate (the design-system origin is always added) |
| `error_reporting.enabled` | production only | subscribe the reporter (below) |
| `error_reporting.async` | `true` | deliver on a background thread |
| `error_reporting.window` | `300` | seconds during which repeats of one fingerprint are counted, not sent |
| `error_reporting.via` | `HubClient#report_error` | callable taking the payload — base, the hub, records its own |
| `error_reporting.ignore` | routing, unknown format, CSRF, bad request, missing param, record not found | error class names never reported |
| `error_reporting.client_errors` | `true` | accept `POST /api/client-errors` and emit the browser hook |

### What the Railtie does at boot

- `config.time_zone` defaults to `PersonalAppClient::TIME_ZONE` (set before
  the app's own configuration, so `application.rb` can still override it —
  the line can go).
- `RateLimit.install!` with `rate_limit` / `rate_limit_rules`, unless the app
  already called `install!` itself (an old `config/initializers/rack_attack.rb`
  keeps working and wins) or set `rate_limit = false`.
- Concerns autoload; `ShellHelper` is in every `ActionController::Base` view;
  the error reporter subscribes when enabled.

### Routes

```ruby
Rails.application.routes.draw do
  personal_app_routes                       # or PersonalAppClient.routes(self)
  # … the app's own routes
end
```

Draws the ten platform routes with the paths, verbs and route names the apps
wrote by hand (`/.well-known/oauth-protected-resource`, `up`
(`rails_health_check`), `/api/health/inter-app`, the six `/api/backup/*`,
`/api/mcp`), plus `GET /manifest.json`, `GET /service-worker.js`,
`GET /offline` and `POST /api/client-errors`. Each group goes to an engine
controller unless the app names its own, or `false` skips it:

```ruby
personal_app_routes backups: "api/backups",       # budgeter: bespoke restore
                    health: "api/health",         # base: also serves /api/health/cluster
                    well_known: "oauth/metadata"  # base: it is the AS
# keys: well_known, up, health, backups, mcp, pwa, client_errors
```

| Default controller | Behaviour |
| --- | --- |
| `PersonalAppClient::McpController` | `McpDispatch` + `OauthResourceServer`, `mcp_server_name`, `mcp_tool_registry` |
| `PersonalAppClient::BackupsController` | `SqliteBackup` with `backup_options` (operator auth in production, as always) |
| `PersonalAppClient::HealthController` | `HealthCheck` with `health_targets` |
| `PersonalAppClient::WellKnownController` | `WellKnown` (an `ActionController::API`) |
| `PersonalAppClient::ClientErrorsController` | the browser error hook, always 204 |
| `PersonalAppClient::PwaController` | manifest, service worker, offline page |

The first four inherit `api_base_controller`, so the app's
`Api::BaseController` before-actions (and `ApplicationController`'s, e.g.
fitness's per-request zone) still run.

### The shell

The app's `app/views/layouts/application.html.erb` becomes the per-app
`content_for` blocks plus one line:

```erb
<% content_for :shell_body_end do %>
  <%= javascript_include_tag "budgeter" %>
<% end %>
<%= render template: "layouts/personal_app/shell" %>
```

(or `layout "personal_app/shell"` when there is nothing to add). The shell is
the chrome every app had — DS CSS and JS, icons, sidebar with `nav-ico` items
and ⌘ hints, empty `sidebar-footer` for the dock, page header, flash, one
`<h1>`, nav hotkeys — plus: a skip link to `<main id="main">` (`sr-only
skip-link`: hidden until the design system gives `.skip-link:focus` a visible
style), a labelled menu button, `viewport-fit=cover` (the DS uses the
safe-area insets), a preload of the self-hosted Inter, `theme-color` per
scheme pinned to the app's own theme (and following `ds:themechange`), the DS
fallback, the manifest, the service-worker registration and the browser error
hook. `aria-current`, `aria-expanded` and modal roles are shared-core's job
and are not duplicated here.

Slots: `:head` (end of `<head>`), `:shell_body_start` (before the sidebar),
`:shell_body_end` (after `</main>`, before the hotkey script), `:extra_js`
(last), and the page slots `:page_title`, `:page_crumb`, `:title_badge`,
`:page_subtitle`, `:header_actions`. Partials (override any of them):
`personal_app/_design_system`, `_sidebar`, `_page_header`, `_flash`.

### Settings panes

```erb
<%= render "personal_app/settings/connector_pane", description: "Lets Claude log work conversationally." %>
<%= render "personal_app/settings/backup_pane" %>
<%= render "personal_app/settings/about_pane", facts: { "Items" => "#{Item.count} tracked" } %>
```

| Partial | Locals (defaults) |
| --- | --- |
| `connector_pane` | `description:`, `tools:` (registry, tool classes or descriptor hashes; default the configured registry), `mcp_url:` (`<request base>/api/mcp`), `auth:` ("OAuth 2.1 · base authorization server"), `hidden:` (true), `pane:` ("connector") |
| `backup_pane` | `title:` ("Backup and restore"), `subtitle:`, `mode:` (`:full` — create/download, recent backups with Download and Restore, Upload ZIP, typed-RESTORE modal, all self-contained; or `:link` — one "Download backup" link), `hidden:`, `pane:` ("data") |
| `about_pane` | `lead:` and `facts:` ([label, value] pairs or a Hash, before Rails and after Host), `connector:` (true — the "N tools over MCP" row), `tools:`, `hidden:`, `pane:` ("about") |

The page still calls `initSettingsPanes()`; the backup pane loads its list on
`settingspane:change`.

### PWA

`/manifest.json` from `app_name` and `pwa`; one shared `/service-worker.js`
(stale-while-revalidate for the design system and the font/library CDNs;
network-first HTML with a 4 s timeout, then the last cached copy of that page,
then `/offline`; `/api/` and non-GETs untouched; caches named per gem version
and deploy, old ones deleted on activate). Registration is production-only by
default; `pwa.service_worker = :unregister` is the kill switch.

### Error reporting

When `error_reporting.enabled?` (production by default) the engine reports:

- exceptions Rails reports to `Rails.error` — an unhandled controller
  exception rendered as a 500, a job that raised inside the executor —
  plus anything the app reports at severity `:error` (handled warnings are
  not);
- 5xx responses that were rendered, not raised (`render status: 500`);
- MCP tool crashes (`McpDispatch` answers those 200 with a JSON-RPC error;
  `ArgumentError` and record-not-found / invalid are bad input, not reported);
- browser errors: the shell's `window.onerror` / `unhandledrejection` hook
  (at most five per page) posts to `POST /api/client-errors`.

Each event gets a fingerprint (kind, class, first app frame without its line
number, message with digits and ids normalised). The first occurrence is
sent; repeats inside `window` are counted and the next send carries `count`.
The default delivery is `HubClient#report_error`, on a background thread:

```
POST <base>/api/error-events/sync          (X-App-Auth)
{ source_app, fingerprint, kind ("server" | "job" | "client"), error_class,
  message, location, backtrace, origin ("Controller#action" | job class | "browser"),
  path, request_method, status, severity, handled, source, revision,
  occurred_at, count }
```

base keys rows on `(source_app, fingerprint)` and adds `count`. Until base has
that endpoint the post 404s and is logged at warn. Delivery never raises into
the failed request or job, and errors raised while delivering are not
reported (no loops).

### Design-system fallback

```sh
bin/rails personal_app:ds:snapshot    # DS_BASE=… to copy from elsewhere
```

Copies the design-system files (and any relative `url()` the stylesheet
references) into `public/ds/`, swapping the directory in only when every file
arrived — a failed run keeps the previous snapshot and does not fail the
deploy. Run it from `bin/deploy`; gitignore `public/ds/`. With the snapshot
present the shell's tags fall back to it when the CDN fails.

### Pinned design system (v0.9.0)

The design system publishes each release under `/v/<sha>/` with a year of
immutable caching and a manifest of sha384 hashes (design-system repo
`scripts/release.mjs`; `v/current.json` is the newest). The gem ships one of
those manifests as `lib/personal_app_client/ds_release.json`, so the shell
loads exactly that release with `integrity` attributes — an altered or
mismatched file is refused (and falls back to `public/ds/` when the snapshot
exists). Moving every app to a new design-system release = copy the new
`v/current.json` over `ds_release.json`, tag the gem, bump the apps (`bin/fleet
gem-bump`). One app can pin differently with `app.ds_release = { "sha" => …,
"files" => { … } }`, or follow the latest with `false`. With `DS_BASE` set (a
local design system) the default is `false`. The design-system release must be
deployed before any app that names its sha.

### Vendored libraries (v0.9.0)

Chart.js and Leaflet are served from the design-system host's `/vendor/`
(pinned, immutable, sha384 in `PersonalAppClient::Vendor::LIBS`) instead of
jsDelivr/unpkg:

```erb
<%= personal_app_vendor_tags "chart.js" %>                     <%# <script … integrity … crossorigin> %>
<script>window.VENDOR = <%= personal_app_vendor_json "leaflet.js", "leaflet.css" %>;</script>  <%# load on demand %>
```

### Content security policy (v0.9.0)

The Railtie sets a policy unless the app has its own: scripts, styles and
fetches from the app itself and the design-system origin only (inline scripts
and handlers stay allowed — the apps use them throughout), images from
anywhere https, `object-src 'none'`, `frame-ancestors 'self'`, and
`report-uri /api/csp-reports`. Violations are reported like browser errors
(`CSPViolation`, one row per directive + blocked origin + page) and reach
base's `/errors` page and the watchdog's new-error page. It starts
`:report_only`; switch an app to `:enforce` (`app.content_security_policy =
:enforce`) once its pages report nothing. `content_security_policy_extra`
adds a source:

```ruby
app.content_security_policy_extra = ->(p) { p.connect_src :self, PersonalAppClient.config.ds_origin, "https://api.example.com" }
```

### Deploy, CI and the page smoke test (v0.9.0)

- `bin/deploy` in every app is a copy of `templates/bin-deploy` (Ruby pick +
  bundle) that ends `exec bundle exec personal-app-deploy` — the gem's
  `exe/personal-app-deploy` does the rest. Change the deploy here, once.
- `.github/workflows/ci.yml` / `deploy.yml` in every app are the callers in
  `templates/workflows/` (only `seed` and `app` differ); the jobs live in this
  repo's `.github/workflows/app-ci.yml` and `app-deploy.yml`, referenced
  `@main`, so a workflow change reaches every app's next run.
- A browser smoke test per app (`test/system/smoke_test.rb`):

  ```ruby
  class SmokeTest < ApplicationSystemTestCase
    include PersonalAppClient::TestSupport::PageSmoke
    smoke_test_pages            # every nav_items path
  end
  ```

  with `driven_by :cuprite, screen_size: [ 1440, 900 ], options:
  PersonalAppClient::TestSupport::PageSmoke.cuprite_options` in
  `test/application_system_test_case.rb`; the shared CI runs it.

### Field-level errors (round three, PLAT-07)

A form error belongs next to its field, not only in a toast. Server-rendered:

```erb
<%= f.text_field :title, class: "form-control", **personal_app_field_aria(@recipe, :title) %>
<%= personal_app_field_error @recipe, :title %>   <%# or render "personal_app/field_error", object:, attribute: %>
```

gives the field `aria-invalid` + `aria-describedby` and a `.form-error` with the
attribute's messages. In the browser, shared-core's `dsFieldErrors(form, {title:
"Title required"})` does the same from a JSON error map (and clears on edit).

### Interoperability

v0.8.0 changes no inter-app wire format: `X-App-Auth`, the health payload
(`ok`, `checked_at`, `revision`, `targets`), the backup endpoints and the
reminder / job-status payloads are what v0.7.0 sends and accepts. The engine
specs run the v0.7.0 code from its tag against a v0.8.0 app to prove it.

## Local dev

```sh
bundle install
bundle exec rake          # unit specs, then the engine specs (twice: lazy and eager loading)
bundle exec rake spec:unit
bundle exec rake spec:engine
```

The unit specs (`spec/personal_app_client/`) run against a fake `::Rails`;
the engine specs (`spec/engine/`) boot the dummy app in `spec/dummy/` in their
own process. To try an unreleased gem in an app, point its Gemfile at the
checkout without committing it: `gem "personal_app_client", path: "../personal-app-client"`.

Releases are git tags; see [CHANGELOG.md](CHANGELOG.md).
