# Changelog

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
