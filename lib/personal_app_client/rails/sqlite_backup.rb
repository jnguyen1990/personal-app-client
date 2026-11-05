require "active_support/concern"
require "active_support/core_ext/object/blank"
require "securerandom"
require "fileutils"
require "pathname"
require_relative "operator_auth"

module PersonalAppClient
  module Rails
    # Shared SQLite backup/restore actions for the personal apps'
    # Api::BackupsController. Provides:
    #
    #   create_backup   — prune → WAL checkpoint (optional) → ZIP (db + extra
    #                     files + ActiveStorage files where configured) → prune
    #   download        — validated filename → send_file from tmp/
    #   list            — JSON listing of tmp/<prefix>_backup_*.zip
    #   prune           — delete all but the newest `keep` ZIPs
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
    #                            exclude_tables: %w[sync_logs]
    #     end
    #
    # Every action is operator-only: the concern includes OperatorAuth, so in
    # production a request needs X-App-Auth (the mini's backup pull) or a
    # valid Cloudflare Access JWT (the settings page). See OperatorAuth.
    #
    # Options:
    #   prefix               backup filename prefix ("<prefix>_backup_<ts>.zip")
    #   keep                 ZIPs retained in tmp/ (default 3); these are only
    #                        staging copies — mini's backup-pull.sh pulls each
    #                        one, verifies integrity_check, and keeps 14 locally
    #   db_entry_name        ZIP entry name for the db (default "<prefix>.db")
    #   extra_files          repo-relative files added to (and restored from) the ZIP
    #   include_storage      include/restore ActiveStorage files under storage/
    #   wal_checkpoint       run PRAGMA wal_checkpoint(TRUNCATE) before zipping
    #                        (default true — without it a WAL-mode db file can
    #                        be missing its most recent writes)
    #   list_include_size    include the raw `size` key in `list` JSON
    #   source_db_path       db path used for create_backup (String/Pathname/Proc);
    #                        defaults to the ActiveRecord connection's db path
    #   exclude_tables       tables the generic restore leaves untouched
    #   tables_delete_order  optional child-first ordering hint for the generic
    #                        restore: listed tables are deleted first, in this
    #                        order (and re-inserted last, reversed); tables not
    #                        listed are still restored
    #
    # The restore pipeline (safety backup → validate ZIP → extract db via
    # File.binwrite — NOT rubyzip Entry#extract, which prepends Dir.pwd even to
    # absolute paths → copy tables) calls `restore_database(temp_db_path,
    # zip_path)`, which apps may override for bespoke row/column mapping. The
    # generic implementation ATTACHes the backup db, toggles
    # PRAGMA foreign_keys OUTSIDE any transaction (a no-op inside one — SQLite
    # gotcha), then replaces the contents of EVERY table present in both the
    # backup and the live database (minus Rails' bookkeeping tables and
    # `exclude_tables`), mapping shared columns (tolerates schema drift), and
    # resets sqlite_sequence. It used to copy only the tables named in
    # `tables_delete_order`, so a table added to the schema but not to that
    # list was silently left out of every restore.
    module SqliteBackup
      extend ActiveSupport::Concern
      include OperatorAuth

      class_methods do
        attr_accessor :sqlite_backup_options

        def sqlite_backup_config(prefix:, keep: 3, db_entry_name: nil, extra_files: [],
                                 include_storage: false, wal_checkpoint: true,
                                 list_include_size: true, source_db_path: nil,
                                 tables_delete_order: [], exclude_tables: [])
          self.sqlite_backup_options = {
            prefix: prefix,
            keep: keep,
            db_entry_name: db_entry_name || "#{prefix}.db",
            extra_files: extra_files,
            include_storage: include_storage,
            wal_checkpoint: wal_checkpoint,
            list_include_size: list_include_size,
            source_db_path: source_db_path,
            tables_delete_order: Array(tables_delete_order).map(&:to_s),
            exclude_tables: Array(exclude_tables).map(&:to_s)
          }.freeze
        end
      end

      def create_backup
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "#{backup_prefix}_backup_#{timestamp}.zip"
        backup_path = ::Rails.root.join("tmp", filename)

        require "zip"

        # Prune BEFORE the checkpoint, not after. Nothing used to delete these
        # ZIPs, so tmp/ grew by one a night until the volume filled and
        # wal_checkpoint(TRUNCATE) started raising SQLITE_FULL — which aborts
        # create_backup before it writes anything, so a prune placed after the
        # write could never run and the job could not recover on its own.
        # Pruning first means a full disk heals itself on the next nightly run.
        pruned = prune_backup_files!

        # Checkpoint WAL so the DB file has all data
        checkpoint_wal! if backup_option(:wal_checkpoint)

        write_backup_zip(backup_path, db_path: backup_source_db_path)

        # Again after the write: the pre-prune left `keep` files, so this drops
        # the oldest to make room for the one just created, landing at exactly
        # `keep`.
        pruned += prune_backup_files!

        render json: {
          success: true,
          filename: filename,
          pruned: pruned,
          download_url: "/api/backup/download/#{filename}"
        }
      rescue => e
        render json: { error: e.message }, status: 500
      end

      # Standalone prune, so a volume that is ALREADY full can be cleared
      # without going through create_backup (which needs free space to get as
      # far as writing a ZIP). Accepts ?keep= to override the configured value.
      def prune
        keep = params[:keep].present? ? params[:keep].to_i : backup_keep
        return render(json: { error: "keep must be >= 1" }, status: 400) if keep < 1

        before = backup_files
        pruned = prune_backup_files!(keep: keep)

        render json: {
          success: true,
          pruned: pruned,
          kept: before.size - pruned.size,
          bytes_freed: pruned.sum { |p| p[:size] }
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
      # Table and column names come from the two databases' own sqlite_master
      # / table_info — never from user input — and are quoted regardless.
      def restore_database(temp_db_path, zip_path)
        conn = ActiveRecord::Base.connection
        conn.execute("ATTACH DATABASE #{conn.quote(temp_db_path)} AS bk")

        begin
          # Child-first for the delete, parent-first for the insert.
          delete_order = restore_delete_order(restorable_tables(conn, "bk") & restorable_tables(conn, "main"))
          insert_order = delete_order.reverse

          # SQLite requires PRAGMA foreign_keys to be toggled OUTSIDE any transaction —
          # it's a no-op if executed while a BEGIN is pending. With it off, the
          # order below cannot fail a constraint, so tables missing from
          # tables_delete_order are safe to copy in any position.
          conn.execute("PRAGMA foreign_keys = OFF")
          begin
            conn.transaction do
              delete_order.each do |table|
                conn.execute("DELETE FROM #{conn.quote_table_name(table)}")
              end

              insert_order.each do |table|
                quoted = conn.quote_table_name(table)
                # Columns that exist in both source and destination
                columns = conn.execute("PRAGMA bk.table_info(#{quoted})").map { |c| c["name"] }
                dest_columns = conn.execute("PRAGMA main.table_info(#{quoted})").map { |c| c["name"] }
                shared_columns = columns & dest_columns

                next if shared_columns.empty?

                cols = shared_columns.map { |c| conn.quote_column_name(c) }.join(", ")
                conn.execute("INSERT INTO #{quoted} (#{cols}) SELECT #{cols} FROM bk.#{quoted}")
              end

              insert_order.each { |table| reset_sequence(conn, table) }
            end
          ensure
            conn.execute("PRAGMA foreign_keys = ON")
          end
        ensure
          begin; conn.execute("DETACH DATABASE bk"); rescue; end
        end

        restore_storage_files(zip_path) if backup_option(:include_storage)
      end

      # User tables in one attached schema ("main" or "bk"): everything except
      # SQLite's own tables, Rails' bookkeeping, virtual tables (their content
      # lives in ordinary shadow tables, which ARE copied) and exclude_tables.
      def restorable_tables(conn, schema)
        conn.execute(
          "SELECT name FROM #{schema}.sqlite_master WHERE type='table' " \
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'ar_internal_%' " \
          "AND name != 'schema_migrations' " \
          "AND (sql IS NULL OR sql NOT LIKE 'CREATE VIRTUAL TABLE%')"
        ).map { |r| r["name"] } - Array(backup_option(:exclude_tables))
      end

      # Configured tables first, in their configured (child-first) order;
      # every other table follows.
      def restore_delete_order(tables)
        listed = tables_delete_order & tables
        listed + (tables - listed).sort
      end

      # Point the table's AUTOINCREMENT counter at its highest restored id.
      # Skipped where that is meaningless: no sqlite_sequence table at all (no
      # AUTOINCREMENT table in the schema), no `id` column (join tables), or
      # an id that is not an integer (uuid / string keys).
      def reset_sequence(conn, table)
        return unless sqlite_sequence?(conn)

        quoted = conn.quote_table_name(table)
        id_column = conn.execute("PRAGMA main.table_info(#{quoted})").find { |c| c["name"] == "id" }
        return unless id_column && id_column["type"].to_s.match?(/int/i)

        max_id = conn.select_value("SELECT MAX(id) FROM #{quoted}")
        return unless max_id.is_a?(Integer)

        name = conn.quote(table)
        existing = conn.select_value("SELECT COUNT(*) FROM sqlite_sequence WHERE name = #{name}")
        if existing && existing > 0
          conn.execute("UPDATE sqlite_sequence SET seq = #{max_id} WHERE name = #{name}")
        else
          conn.execute("INSERT INTO sqlite_sequence (name, seq) VALUES (#{name}, #{max_id})")
        end
      end

      def sqlite_sequence?(conn)
        conn.select_value(
          "SELECT COUNT(*) FROM main.sqlite_master WHERE type='table' AND name='sqlite_sequence'"
        ).to_i > 0
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

      # Never 0 or negative: `keep` reaches Array#drop, where 0 would prune
      # every backup the app has. A controller whose sqlite_backup_config
      # predates the :keep option reads nil here, hence the floor.
      def backup_keep
        keep = backup_option(:keep).to_i
        keep < 1 ? 3 : keep
      end

      def backup_filename_regexp
        /\A#{Regexp.escape(backup_prefix)}_backup_\d{8}_\d{6}\.zip\z/
      end

      # This app's backup ZIPs in tmp/, newest first. Sorted by the filename's
      # embedded timestamp rather than mtime (as `list` uses): the %Y%m%d_%H%M%S
      # format sorts lexicographically, and unlike mtime it survives a copy or
      # a restore that rewrites the file. The regexp filter keeps the glob from
      # matching anything else that happens to live in tmp/.
      def backup_files
        Dir.glob(::Rails.root.join("tmp", "#{backup_prefix}_backup_*.zip"))
           .select { |path| File.basename(path).match?(backup_filename_regexp) }
           .sort_by { |path| File.basename(path) }
           .reverse
      end

      # Delete all but the newest `keep` ZIPs. Returns [{filename:, size:}, …]
      # for what it removed. A file that will not unlink is skipped rather than
      # raised on — losing a prune is recoverable, losing the backup it is
      # clearing space for is not.
      def prune_backup_files!(keep: backup_keep)
        backup_files.drop(keep).filter_map do |path|
          size = File.size(path)
          begin
            File.unlink(path)
            { filename: File.basename(path), size: size }
          rescue SystemCallError => e
            ::Rails.logger.warn("[sqlite_backup] could not prune #{path}: #{e.message}")
            nil
          end
        end
      end

      def tables_delete_order
        Array(backup_option(:tables_delete_order))
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
