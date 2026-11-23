# Changelog

## 0.8.0

The gem becomes a Rails engine as well: the platform routes, the default
controllers, the layout shell, the settings panes, PWA and error reporting
that the apps each carried a copy of. Adoption is opt-in per piece — bumping
the tag from v0.7.0 changes only what is listed under "Behaviour changes on
bump"; everything else applies once an app calls `personal_app_routes`,
renders the shell or the panes. Adoption guide: the README's
"The engine (v0.8.0)" section.

### Behaviour changes on bump

- **The engine loads inside every Rails app** (`Bundler.require`). On its own
  it changes nothing visible, except:
  - `config.time_zone` defaults to `PersonalAppClient::TIME_ZONE` before the
    app's configuration runs (every app already set the same value).
  - **Rate limiting is installed by the Railtie** with the gem defaults
    (120/min per IP on `/api/`) unless the app's own initializer already
    called `RateLimit.install!` (it then wins, as before) or
    `config.rate_limit = false`.
  - **Error reporting is on in production**: unhandled exceptions, rendered
    5xx responses and MCP tool crashes are posted to base's
    `POST /api/error-events/sync`, deduplicated. Until base has that
    endpoint each first occurrence logs one warn line. Off with
    `config.error_reporting.enabled = false`.
  - `McpDispatch` reports a crashing tool to `Rails.error` (it still answers
    with the JSON-RPC -32603 error).
- **`SqliteBackup` restore writes only what it owns.** `extra_files`
  (CLAUDE.md, README.md) are no longer written back from the ZIP — a restore
  used to overwrite the app's checked-out copies with old ones. With
  `include_storage`, `storage_files/` entries are written only when they are
  regular files resolving inside `storage/`: absolute names, `..` traversal,
  symlinks and `.sqlite3` files (the live databases live in `storage/`) are
  skipped and logged. Matters most for `restore_upload`, which takes any ZIP.
- `SqliteBackup` never writes into an existing ZIP: a second backup in the
  same second (including the safety backup of a restore run right after a
  create — previously written into the ZIP being restored) takes the next
  free second's name.
- Development dependencies: railties, actionpack, actionview, rack-test.
  Runtime dependencies are unchanged; the engine needs Rails >= 7.1.

### Added

- `PersonalAppClient::Engine` (not isolated) with a Railtie: time zone, rate
  limiting, error reporting, `ShellHelper` in every view, the
  `personal_app:ds:snapshot` rake task.
- `PersonalAppClient.configure` / `.config` — `app_id`, `app_name`,
  `nav_items`, `ds_scripts`, `header_style`, `subtitle_tag`, `nav_hotkeys`,
  `ds_base`, `ds_fallback`, `api_base_controller`, `mcp_server_name`,
  `mcp_tool_registry`, `backup`, `health_targets`, `rate_limit`,
  `rate_limit_rules`, `pwa.*`, `error_reporting.*`.
- Autoloading for every optional module (`Rails::*` concerns,
  `Mcp::BaseTool`, `Mcp::Registry`, `RateLimit`, `TestSupport`,
  `CloudflareAccess`, …): the per-concern `require` lines are optional.
- `personal_app_routes` (also `PersonalAppClient.routes(self)`): the ten
  platform routes with unchanged paths, verbs and names, plus
  `/manifest.json`, `/service-worker.js`, `/offline` and
  `POST /api/client-errors`; per-group controller overrides or `false`.
- Default controllers: `PersonalAppClient::McpController`,
  `BackupsController`, `HealthController`, `WellKnownController`,
  `ClientErrorsController`, `PwaController`, and `ApiController` (the parent
  when an app has no `Api::BaseController`).
- `layouts/personal_app/shell` — the shared chrome driven by `nav_items` and
  `data-app`, with slots (`:head`, `:shell_body_start`, `:shell_body_end`,
  `:extra_js`) and overridable partials (`personal_app/_design_system`,
  `_sidebar`, `_page_header`, `_flash`). New in the chrome: skip link to
  `main#main` (`sr-only skip-link`), `aria-label` on the menu button,
  `viewport-fit=cover`, a preload of the self-hosted Inter, `theme-color`
  pinned to the app's theme, design-system fallback to `public/ds/`,
  manifest, service-worker registration, browser error hook. Rendered
  against each app's current layout the DOM is otherwise identical.
- Settings-pane partials: `personal_app/settings/connector_pane`,
  `backup_pane` (`:full` or `:link`), `about_pane`.
- PWA: manifest from config, one shared service worker (stale-while-revalidate
  design system and CDNs, network-first HTML, offline page, per-release
  caches, `:unregister` kill switch).
- `PersonalAppClient::ErrorReporting` (`Rails.error` subscriber, 5xx
  subscriber, `Deduper`, fingerprints) and `HubClient#report_error`
  (`ERROR_EVENT_KEYS`).
- `PersonalAppClient::DsSnapshot` and `personal_app:ds:snapshot`.
- `PersonalAppClient::Nav` (nav item active rules) and `RateLimit.installed?`.
- A dummy Rails app (`spec/dummy`) and engine specs (`spec/engine`), including
  route parity with the hand-written routes and interoperability with the
  v0.7.0 code from its tag. `rake` runs unit and engine specs.

### Unchanged on the wire

`X-App-Auth`, the `/api/health/inter-app` payload, the backup endpoints and
the reminder / job-status payloads (`REMINDER_KEYS`, `JOB_STATUS_KEYS`) are
exactly v0.7.0's, so postings on v0.7.0 and upgraded apps interoperate.

## 0.7.0

Hoists code the six apps each carried a private copy of. Bumping the tag from
v0.6.0 changes nothing an app has to react to, with one intended exception.

### Behaviour changes on bump

- **Backup endpoints require auth in production.** `SqliteBackup` now includes
  `OperatorAuth`: in production every `/api/backup/*` action needs `X-App-Auth`
  matching `INTER_APP_SECRET` (the mini's backup pull already sends it) or a
  valid Cloudflare Access JWT (the settings page). Other environments are
  unchanged.
- `SqliteBackup` restore covers **every table** present in both the backup and
  the live database, not just those named in `tables_delete_order` — tables
  that had fallen off an app's list were silently skipped. `tables_delete_order`
  is now an optional ordering hint; new `exclude_tables:` option.
- `SqliteBackup` `wal_checkpoint` defaults to `true`.
- `SqliteBackup` sequence reset skips tables with no `id` column, non-integer
  ids, and databases with no `sqlite_sequence` table, instead of raising.
- `Mcp::BaseTool.parse_date` is strict: exactly `YYYY-MM-DD` and a real date.
  `"05"`, `"next tuesday"`, `"July 6"` and `2026-02-30` now raise the same
  `ArgumentError` garbage always did.
- New runtime dependencies: `tzinfo-data >= 1.2026.6` and `rack-attack >= 6.6`.

### Added

- `PersonalAppClient::TIME_ZONE` (`"America/Winnipeg"`), with `tzinfo-data`
  required so TZInfo uses bundled zone data rather than the OS's — Manitoba
  moved to permanent UTC−5 on 2026-10-31.
- `PersonalAppClient.revision` — deployed git SHA from `REVISION` or `.git`,
  no subprocess.
- `PersonalAppClient::Dates` and `Rails::DateParams` (`parse_date_param`,
  `parse_month_param`); `Mcp::BaseTool.parse_date_arg!`.
- `PersonalAppClient::CloudflareAccess.verify` and `Rails::OperatorAuth`.
- `PersonalAppClient::JwksCache` — the JWKS fetch/cache/stale-reuse code,
  moved out of `OauthResourceServer` and shared with `CloudflareAccess`.
- `Client#patch`, `Client#last_status`.
- `PersonalAppClient::AppClient` (base class for per-app client wrappers, with
  `ping`) and `PersonalAppClient::HubClient` (`sync_reminder`,
  `delete_reminder`, `report_job_status`).
- `Rails::HealthCheck`, `Rails::WellKnown`, `Rails::ApiErrors`,
  `Rails::JobStatusReporting`, `Rails::SettingStore`.
- `Mcp::Registry`.
- `PersonalAppClient::RateLimit.install!`.
- `PersonalAppClient::TestSupport`.

## 0.6.0

- `SqliteBackup` prunes backup ZIPs in `tmp/` (`keep` option, `prune` action).

## 0.5.0

- `Rails::McpDispatch` and `Rails::SqliteBackup` concerns; `Mcp::BaseTool`.

## 0.4.0

- `Rails::OauthResourceServer` concern; `jwt` dependency.

## 0.3.0

- `Rails::ApiKeyAuth` concern.

## 0.2.x

- `Rails::InterAppAuthOptional` concern; lenient JSON parsing regardless of
  Content-Type.

## 0.1.0

- Initial gem: `Client` for inter-app calls.
