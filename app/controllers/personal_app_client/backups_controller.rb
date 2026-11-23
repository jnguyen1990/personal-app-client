module PersonalAppClient
  # Default /api/backup/*: SqliteBackup configured from config.backup
  # (prefix: app_id, extra_files: CLAUDE.md + README.md unless overridden).
  # Operator auth in production, as SqliteBackup always has.
  #
  # An app with a bespoke restore (budgeter) keeps its own controller:
  # `personal_app_routes backups: "api/backups"`.
  class BackupsController < PersonalAppClient.api_base_controller
    include PersonalAppClient::Rails::SqliteBackup

    sqlite_backup_config(**PersonalAppClient.config.backup_options)
  end
end
