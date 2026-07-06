require "active_support/concern"
require "active_support/core_ext/object/blank"
require "securerandom"
require "fileutils"
require "pathname"

module PersonalAppClient
  module Rails
    # Shared SQLite backup/restore actions for the personal apps'
    # Api::BackupsController. Provides:
    #
    #   create_backup   — WAL checkpoint (optional) → ZIP (db + extra files +
    #                     ActiveStorage files where configured)
    #   download        — validated filename → send_file from tmp/
    #   list            — JSON listing of tmp/<prefix>_backup_*.zip
    #   restore         — restore a named backup from tmp/
    #   restore_upload  — restore from an uploaded ZIP
    #
    # Configure in the including controller:
    #
    #     class Api::BackupsController < BaseController
    #       include PersonalAppClient::Rails::SqliteBackup
    #
    #       sqlite_backup_config prefix: "fitness",
    #                            extra_files: %w[CLAUDE_CONTEXT.md README.md],
    #                            include_storage: true,
    #                            wal_checkpoint: true,
    #                            tables_delete_order: TABLES_DELETE_ORDER
    #     end
    #
    # Options:
    #   prefix               backup filename prefix ("<prefix>_backup_<ts>.zip")
    #   db_entry_name        ZIP entry name for the db (default "<prefix>.db")
    #   extra_files          repo-relative files added to (and restored from) the ZIP
    #   include_storage      include/restore ActiveStorage files under storage/
    #   wal_checkpoint       run PRAGMA wal_checkpoint(TRUNCATE) before zipping
    #   list_include_size    include the raw `size` key in `list` JSON
    #   source_db_path       db path used for create_backup (String/Pathname/Proc);
    #                        defaults to the ActiveRecord connection's db path
    #   tables_delete_order  child-first table list for the generic restore
    #
    # The restore pipeline (safety backup → validate ZIP → extract db via
    # File.binwrite — NOT rubyzip Entry#extract, which prepends Dir.pwd even to
    # absolute paths → copy tables) calls `restore_database(temp_db_path,
    # zip_path)`, which apps may override for bespoke row/column mapping. The
    # generic implementation ATTACHes the backup db, toggles
    # PRAGMA foreign_keys OUTSIDE any transaction (a no-op inside one — SQLite
    # gotcha), deletes child-first, re-inserts parent-first mapping shared
    # columns (tolerates schema drift), and resets sqlite_sequence.
    module SqliteBackup
      extend ActiveSupport::Concern

      class_methods do
        attr_accessor :sqlite_backup_options

        def sqlite_backup_config(prefix:, db_entry_name: nil, extra_files: [],
                                 include_storage: false, wal_checkpoint: false,
                                 list_include_size: true, source_db_path: nil,
                                 tables_delete_order: [])
          self.sqlite_backup_options = {
            prefix: prefix,
            db_entry_name: db_entry_name || "#{prefix}.db",
            extra_files: extra_files,
            include_storage: include_storage,
            wal_checkpoint: wal_checkpoint,
            list_include_size: list_include_size,
            source_db_path: source_db_path,
            tables_delete_order: tables_delete_order
          }.freeze
        end
      end

      def create_backup
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "#{backup_prefix}_backup_#{timestamp}.zip"
        backup_path = ::Rails.root.join("tmp", filename)

        require "zip"

        # Checkpoint WAL so the DB file has all data
        checkpoint_wal! if backup_option(:wal_checkpoint)

        write_backup_zip(backup_path, db_path: backup_source_db_path)

        render json: {
          success: true,
          filename: filename,
          download_url: "/api/backup/download/#{filename}"
        }
      rescue => e
        render json: { error: e.message }, status: 500
      end

      def download
        filename = File.basename(params[:filename].to_s)

        unless filename.match?(backup_filename_regexp)
          return render(json: { error: "Invalid filename" }, status: 400)
        end

        path = ::Rails.root.join("tmp", filename)
        return render(json: { error: "File not found" }, status: 404) unless File.exist?(path)

        send_file path, type: "application/zip", disposition: "attachment", filename: filename
      end

      def list
        backups = Dir.glob(::Rails.root.join("tmp", "#{backup_prefix}_backup_*.zip")).map do |path|
          filename = File.basename(path)
          size = File.size(path)
          entry = {
            filename: filename,
            size: size,
            size_mb: (size / (1024.0 * 1024.0)).round(2),
            created: File.mtime(path).strftime("%Y-%m-%d %H:%M:%S"),
            download_url: "/api/backup/download/#{filename}"
          }
          entry.delete(:size) unless backup_option(:list_include_size)
          entry
        end.sort_by { |b| b[:created] }.reverse

        render json: backups
      end

      def restore
        filename = File.basename(params[:filename].to_s)

        unless filename.match?(backup_filename_regexp)
          return render(json: { error: "Invalid filename" }, status: 400)
        end

        zip_path = ::Rails.root.join("tmp", filename)
        return render(json: { error: "Backup file not found" }, status: 404) unless File.exist?(zip_path)

        perform_restore(zip_path)
      end

      def restore_upload
        file = params[:file]
        return render(json: { error: "No file uploaded" }, status: 400) unless file.present?

        unless file.original_filename.end_with?(".zip")
          return render(json: { error: "File must be a .zip archive" }, status: 400)
        end

        tmp_path = ::Rails.root.join("tmp", "restore_upload_#{SecureRandom.hex(8)}.zip")
        FileUtils.cp(file.tempfile.path, tmp_path.to_s)

        begin
          perform_restore(tmp_path)
        ensure
          FileUtils.rm_f(tmp_path)
        end
      end

      private

      def perform_restore(zip_path)
        require "zip"

        db_entry = backup_option(:db_entry_name)

        # Validate ZIP contains the db entry
        unless Zip::File.open(zip_path.to_s) { |z| z.find_entry(db_entry).present? }
          return render(json: { error: "Invalid backup: missing #{db_entry}" }, status: 422)
        end

        # Create safety backup first
        safety_timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        safety_filename = "#{backup_prefix}_backup_#{safety_timestamp}.zip"
        safety_path = ::Rails.root.join("tmp", safety_filename)

        checkpoint_wal! if backup_option(:wal_checkpoint)
        write_backup_zip(safety_path, db_path: resolved_db_path)

        # Extract the db (and extra files) from the ZIP
        temp_db_path = ::Rails.root.join("tmp", "restore_#{SecureRandom.hex(8)}.sqlite3").to_s
        begin
          Zip::File.open(zip_path.to_s) do |z|
            File.binwrite(temp_db_path, z.read(db_entry))
            backup_option(:extra_files).each do |f|
              File.binwrite(::Rails.root.join(f).to_s, z.read(f)) if z.find_entry(f)
            end
          end

          restore_database(temp_db_path, zip_path)
          return if performed?

          render json: { success: true, message: "Database restored successfully", safety_backup: safety_filename }
        rescue => e
          begin; ActiveRecord::Base.connection.execute("PRAGMA foreign_keys = ON"); rescue; end
          render json: { error: "Restore failed: #{e.message}" }, status: 500
        ensure
          FileUtils.rm_f(temp_db_path)
        end
      end

      # Generic table-copy restore. Apps with bespoke schemas/legacy column
      # mapping override this method (render inside it to abort — the shared
      # success response is skipped when a response was already rendered).
      #
      # Table names are interpolated from the configured tables_delete_order
      # constant — never from user input.
      def restore_database(temp_db_path, zip_path)
        conn = ActiveRecord::Base.connection
        conn.execute("ATTACH DATABASE #{conn.quote(temp_db_path)} AS bk")

        begin
          backup_tables = conn.execute(
            "SELECT name FROM bk.sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'ar_internal_%' AND name != 'schema_migrations'"
          ).map { |r| r["name"] }

          # SQLite requires PRAGMA foreign_keys to be toggled OUTSIDE any transaction —
          # it's a no-op if executed while a BEGIN is pending.
          conn.execute("PRAGMA foreign_keys = OFF")
          begin
            conn.transaction do
              # Delete all data in child-first order
              tables_delete_order.each do |table|
                conn.execute("DELETE FROM #{table}") if backup_tables.include?(table)
              end

              # Insert from backup in parent-first order
              tables_insert_order.each do |table|
                next unless backup_tables.include?(table)

                # Get column list from backup table
                columns = conn.execute("PRAGMA bk.table_info(#{table})").map { |c| c["name"] }
                # Get columns that exist in both source and destination
                dest_columns = conn.execute("PRAGMA table_info(#{table})").map { |c| c["name"] }
                shared_columns = columns & dest_columns

                next if shared_columns.empty?

                cols = shared_columns.join(", ")
                conn.execute("INSERT INTO #{table} (#{cols}) SELECT #{cols} FROM bk.#{table}")
              end

              # Reset auto-increment sequences
              tables_insert_order.each do |table|
                next unless backup_tables.include?(table)
                max_id = conn.select_value("SELECT MAX(id) FROM #{table}")
                if max_id
                  existing = conn.select_value("SELECT COUNT(*) FROM sqlite_sequence WHERE name = '#{table}'")
                  if existing && existing > 0
                    conn.execute("UPDATE sqlite_sequence SET seq = #{max_id} WHERE name = '#{table}'")
                  else
                    conn.execute("INSERT INTO sqlite_sequence (name, seq) VALUES ('#{table}', #{max_id})")
                  end
                end
              end
            end
          ensure
            conn.execute("PRAGMA foreign_keys = ON")
          end
        ensure
          begin; conn.execute("DETACH DATABASE bk"); rescue; end
        end

        restore_storage_files(zip_path) if backup_option(:include_storage)
      end

      # Restore ActiveStorage blob files.
      # Note: don't use Zip::Entry#extract here — rubyzip prepends Dir.pwd even
      # to absolute destination paths, producing a doubled path. Read + binwrite
      # instead, matching the pattern used for the db file above.
      def restore_storage_files(zip_path)
        Zip::File.open(zip_path.to_s) do |z|
          z.each do |entry|
            next unless entry.name.start_with?("storage_files/")
            relative = entry.name.sub("storage_files/", "")
            next if relative.empty?
            dest = ::Rails.root.join("storage", relative)
            FileUtils.mkdir_p(File.dirname(dest))
            File.binwrite(dest.to_s, z.read(entry.name))
          end
        end
      end

      def write_backup_zip(zip_out_path, db_path:)
        require "zip"

        Zip::File.open(zip_out_path.to_s, create: true) do |zipfile|
          # Add extra files (markdown context docs etc.)
          backup_option(:extra_files).each do |file|
            path = ::Rails.root.join(file)
            zipfile.add(file, path.to_s) if File.exist?(path)
          end

          # Add database
          zipfile.add(backup_option(:db_entry_name), db_path.to_s) if File.exist?(db_path)

          # Add ActiveStorage blob files
          if backup_option(:include_storage)
            storage_root = ::Rails.root.join("storage")
            if storage_root.exist?
              Dir.glob(storage_root.join("**", "*")).each do |file_path|
                next if File.directory?(file_path)
                next if file_path.match?(/\.sqlite3/)
                next if File.basename(file_path) == ".keep"
                relative = Pathname.new(file_path).relative_path_from(storage_root).to_s
                zipfile.add("storage_files/#{relative}", file_path)
              end
            end
          end
        end
      end

      def checkpoint_wal!
        ActiveRecord::Base.connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
      end

      # The live database file path per the ActiveRecord connection config.
      def resolved_db_path
        db_path = ActiveRecord::Base.connection_db_config.database
        db_path.start_with?("/") ? db_path : ::Rails.root.join(db_path).to_s
      end

      # The db file zipped by create_backup (configurable for apps that back
      # up a fixed path); safety backups always use resolved_db_path.
      def backup_source_db_path
        source = backup_option(:source_db_path)
        case source
        when nil then resolved_db_path
        when Proc then instance_exec(&source)
        else source
        end
      end

      def backup_prefix
        backup_option(:prefix)
      end

      def backup_filename_regexp
        /\A#{Regexp.escape(backup_prefix)}_backup_\d{8}_\d{6}\.zip\z/
      end

      def tables_delete_order
        backup_option(:tables_delete_order)
      end

      # Tables in parent-first order for insertion (reverse of delete)
      def tables_insert_order
        tables_delete_order.reverse
      end

      def backup_option(key)
        (self.class.sqlite_backup_options || {})[key]
      end
    end
  end
end
