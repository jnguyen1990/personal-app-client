# Changelog

## 0.10.5

- **Design system pinned to 5c8b1aa84704:** round six styles for budgeter (allocation references, pace notes, touch targets, reports), mealplanner (recipe form, nutrition grid, Today page) and upkeep (quiet row actions, plan casing, This month, garage cards with 12-month strips, year view, item records, library).

## 0.10.4

- **Design system pinned to bb612d0c4ae3:** planned lifts without a weight read "—" instead of "undefined lbs" (names and notes escaped); planned fitness calendar cards keep their sport stripe.

## 0.10.3

### Behaviour changes on bump
- **Design system pinned to 26b091f1877b** — deploy the design system first.

### From the design system (26b091f1877b), no app changes needed
- **Wider pages:** `--content-max: 1600px` (was 1200); prose held to `--measure` (72ch); `.table-fit` opt-in for short tables; shared `.chart-box` (fixed-height charts). `.content-narrow` unchanged. (Joe, 2026-11-25)
- Running is blue (red is for errors), swimming indigo.
- `SessionRender.vitalsChip` is an emoji-free vitals line (sleep, steps, resting HR, HRV; sleep under 6 h amber); same signature.
- No 175 W FTP guess: without an FTP the plan table shows % of FTP only.
- Fitness round five styles in `apps/fitness.css`.

## 0.10.2

### Behaviour changes on bump
- **Tailnet requests stay plain http** (`TailnetSSL`): with `config.assume_ssl`, a request to a `*.ts.net` host is no longer marked https, and `force_ssl` skips its https redirect for it (an app's own `ssl_options[:redirect][:exclude]` is kept). Redirects over `http://<app>.tail5ece07.ts.net:3000` now stay on http — before, every one pointed at an https address nothing serves (base's `/jobs` → `/status`, 2026-11-25). The public `https://<app>.joenguyen.ca` door is unchanged: still https, Secure cookies, HSTS.

## 0.10.1

### Behaviour changes on bump
- **Design system pinned to b71fc01cc85f** (`ds_release.json`) — deploy the design system first.

### From the design system (b71fc01cc85f), no app changes needed
- Sentence case: the forced `text-transform: lowercase` is gone from `.cal-day-name`, `.cal-slot-type`, `.cal-dow`, `.sess-day` and fitness's `.ws-h`, `.gm-label`, `.day-name` — apps send the text as it should read (BASE-39).
- Three `.stat-card` tiles stay on one row between 481 and 768px (BASE-05).
- `apps/base.css`: inbox, status page and agent page styles (AGT-D, AGT-H, AGT-06).

## 0.10.0

### Behaviour changes on bump
- **Design system pinned to c73747cc1042** (`ds_release.json`) — deploy the design system first.
- **The shell links the app's own stylesheet** `apps/<app_id>.css` right after `design-system.css`, from the same pinned release with its integrity hash and snapshot fallback; `personal_app:ds:snapshot` copies it too (`config.ds_snapshot_files`). `config.app_stylesheet = false` keeps the shared file only. (PLAT-27)
- **Settings and new/edit pages render narrow** (~720px, design system `.content-narrow`). `config.narrow_pages` — Regexps on `request.path`, exact path Strings or Procs taking the request; default `[%r{\A/settings(/|\z)}, %r{/(new|edit)\z}]`. A page overrides with `content_for :content_width, "narrow" | "wide"`. (PLAT-22)
- **The inline page header is one grid** (`.page-header-inline`: title + badge, actions, subtitle). Desktop looks the same; on a phone the actions wrap below the title and subtitle. An app overriding `_page_header` or styling `header > .page-subtitle` should check. (PLAT-09)
- **Flash messages are live regions** (`role="status"`, alerts `role="alert"`). (PLAT-06)

### Added
- **⌘K command palette** (PLAT-17): `config.palette` (default true) renders `<meta name="ds-palette" content="<search url or empty>">` and a "Search ⌘K" control under the sidebar brand and in the phone More sheet. It lists the sidebar's pages, this app's records and actions; apps register actions with `dsCommands.register({ label, icon, keywords, run | url })` (e.g. in `content_for :shell_body_end`). `false` = no palette.
- **Command-palette search** (PLAT-18): `GET /api/search?q=&limit=` answers this app's own records from `config.search`, a callable `(query, limit:)` returning hashes with `kind`, `title`, `meta`, a same-origin `url` and an optional `preview` (`heading`, `subheading`, `amount`, `amount_tone`, `fields`, `actions`). Results are normalised, plain text and capped (limit 5 by default, max 20; query 2–100 characters, else 422); a raising search answers no results and is reported. Drawn by `personal_app_routes` (group `search:`; `false` skips it). No cross-app calls.
- **Field errors** (PLAT-07): `personal_app_field_error` / `personal_app_field_aria` and a `personal_app/_field_error` partial for server-rendered forms (the design system's `dsFieldErrors` is the JS side).
- The offline page reads the shared `ds_theme` cookie before localStorage. (PLAT-10)

### From the design system (c73747cc1042), no app changes needed
- Contrast floor: links, five chip hues, three toasts, `--border-control` for field outlines (PLAT-01/02/03); keyboard dropdowns and filter tags (PLAT-04/05); `showStatus`/`dsToast` live regions (PLAT-06).
- Theme shared across `*.joenguyen.ca` via the `ds_theme` cookie on `.joenguyen.ca` (localhost / tailnet keep localStorage). (PLAT-10)
- Compact density from the palette (`data-density="compact"`, stored like the theme; mouse/trackpad only). (PLAT-16)
- Pages cross-fade on navigation; sidebar, header and tab bar hold still; off under reduced motion. (PLAT-15)
- 44px tap areas on touch for dock icons, button badges, `.btn-sm`, `.btn-icon`. (PLAT-08)
- Type tokens: `--text-3xs`, `--tracking-*` (PLAT-30); dead rules and tokens removed (PLAT-28/29).

## 0.9.1

- **Fix: `bundle exec personal-app-deploy` works.** Bundler's wrapper for a
  gem executable `load`s it as Ruby, so v0.9.0's bash `exe/personal-app-deploy`
  failed the first deploy with a SyntaxError (before migrating or restarting —
  the app kept running the old code). The steps moved to
  `libexec/personal-app-deploy.sh`; `exe/personal-app-deploy` is a Ruby shim
  that execs it.

## 0.9.0

### Behaviour changes on bump

- **The design system loads from the pinned release** (`/v/8dfdc092a76d/`,
  with integrity) instead of the always-latest URLs — deploy the design
  system first. (`ds_release.json` = design system 8dfdc092a76d.) Set `ds_release = false` to keep the old behaviour.
- **A report-only Content-Security-Policy header** on every response (blocks
  nothing; violations reach base's /errors).
- **A POST or PATCH is no longer re-sent when the connection drops
  mid-request** (`Errno::ECONNRESET`, `EOFError`): it may already have been
  performed. GET, PUT and DELETE still retry once; a POST/PATCH retries only
  with `idempotent: true` (`client.post(path, body, idempotent: true)`).
  Failures before the request left (`ECONNREFUSED`, `EHOSTUNREACH`,
  `Net::OpenTimeout`) still retry for every method. Net::HTTP's own silent
  retry is turned off so this is the only one. The HubClient's reminder sync
  and job-status calls are marked idempotent (upserts). An app's own
  create-style POSTs need nothing; its upserts (goal/block sync) should pass
  `idempotent: true` to keep the retry. (PLAT-38)

### Added

- `AppClient#attempt!(label) { |http| … }` — the raising twin of `attempt`:
  logs, then re-raises the PersonalAppClient error (ConfigurationError when
  unconfigured). For sync writes, so a failed write to base is a failed job
  run instead of a logged nil that looks like success. `HubClient#sync_reminder!`
  and `#delete_reminder!` are built on it. (PLAT-39)
- `PersonalAppClient::Rails::TransientRetries` — include it in
  `ApplicationJob` (after JobStatusReporting) and a job that fails on a
  network blip, a sibling's deploy restart or SQLite's "database is locked"
  runs again up to 3 times in all (polynomial backoff) instead of failing
  until its next scheduled run. An attempt that will be retried reports
  nothing to /jobs; the last one reports ok or fail. (PLAT-59)
- `MCP_OAUTH_JWKS_FILE`: when it names a readable JWKS file (provisioning
  writes base's public keys into each container), connector tokens are
  verified against it first and the network is asked only for a key id the
  file lacks (a rotated key). An app restarted while base is down keeps
  accepting connector calls. Unset or missing file = the network fetch as
  before. (PLAT-60)
- **Pinned design system** (PLAT-26): `config.ds_release` — the shell loads
  `<ds_base>/v/<sha>/<file>` with `integrity` + `crossorigin` for every file
  in the release this gem ships (`ds_release.json`, design system
  8dfdc092a76d). `false` or `DS_BASE` = unversioned as before.
- **Vendored libraries** (PLAT-11): `personal_app_vendor_tags` /
  `personal_app_vendor_json` for Chart.js 4.6.1 and Leaflet 1.9.4 from the
  design-system host's `/vendor/`, with integrity.
- **Content security policy** (PLAT-25): set by the Railtie unless the app
  has its own; `config.content_security_policy` `:report_only` (default),
  `:enforce` or `false`; violations to `POST /api/csp-reports` → base's
  /errors as `CSPViolation`.
- **One deploy script** (PLAT-43): `exe/personal-app-deploy` (migrate,
  precompile, design-system snapshot, systemd unit sync, restart) is the gem's
  executable; each app's `bin/deploy` becomes `templates/bin-deploy` — pick the
  Ruby, bundle, `exec bundle exec personal-app-deploy` — identical in every
  app. It also fixes a silent exit when no Ruby is installed.
- **One CI and one deploy workflow** (PLAT-42): `.github/workflows/app-ci.yml`
  and `app-deploy.yml` (`workflow_call`, this repo is public); each app's
  `ci.yml` / `deploy.yml` become the short callers in `templates/workflows/`.
  The CI adds a browser smoke-test step that runs `test:system` when the app
  has one.
- **Request log** (PLAT-51): one `request method=… path=… status=…
  duration_ms=… db_ms=… view_ms=… controller=…` line per request, production
  by default (`config.request_log`).
- **Page smoke test** (PLAT-52): `PersonalAppClient::TestSupport::PageSmoke`
  — `smoke_test_pages` defines one Capybara/Cuprite system test per nav page
  that fails on an error status, an uncaught exception, an unhandled
  rejection or `console.error`. Apps add `capybara` + `cuprite` to the test
  group.
- **One list of apps** (PLAT-44): `lib/personal_app_client/apps.json` (id,
  name, dock name, accent, public/tailnet/dev URLs, MCP resource, repo, CT
  id) → `PersonalAppClient.apps` / `.app(id)` / `Apps.mcp_resources`. The
  shell renders it as `window.PERSONAL_APPS` for the launcher dock (design
  system 8dfdc092a76d reads it); base and the mini's scripts read it too.

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

### Shell: mobile tab bar and the flat design system (design system v4.4)

- **Mobile tab bar.** The shell renders `personal_app/_tab_bar` after
  `<main>`: a `.tab-bar` with the first four nav items (or the ones marked
  `tab: true`; `tab: false` keeps one out) plus a "More" button that opens a
  `.sheet` bottom sheet holding the other items and the app dock. Below
  768px the design system shows it in place of the hamburger + drawer (the
  hamburger markup stays for apps or pages without a tab bar). Tabs carry
  `aria-current="page"`; shared-core.js handles the sheet's focus, Esc and
  scrim. New config: `tab_bar` (default `true`), `tab_count` (default 4);
  `Nav::Item#tab`, `Nav.tabs`, `personal_app_tab_items`. Needs the design
  system with the tab bar (v4.4) live first.
- `pwa.theme_colors` defaults to `#ffffff` light (the flat model's page
  sheet), was `#f9f9fb`.
- Backup pane: the restore modal's "Restoring <file>" line has spacing
  above and below it.

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
