require "ostruct"
require "logger"
require "tmpdir"
require "pathname"
require "active_record"
require "zip"
require "personal_app_client/rails/sqlite_backup"

# Minimal Rails stand-in — the backup concern touches ::Rails.root and, on the
# prune path, ::Rails.logger.
module Rails
  def self.root
    @root ||= Pathname.new(Dir.mktmpdir("pac_sqlite_backup"))
  end

  def self.logger
    @logger ||= Logger.new(File::NULL)
  end
end

class FakeBackupsController
  # The concern includes OperatorAuth, which registers a before_action.
  def self.before_actions
    @before_actions ||= []
  end

  def self.before_action(method_name, **_options)
    before_actions << method_name
  end

  attr_accessor :params
  attr_writer :request
  attr_reader :rendered, :sent_file

  def initialize
    @params = {}
  end

  def request
    @request ||= OpenStruct.new(headers: {}, cookies: {})
  end

  def render(payload)
    @rendered = payload
  end

  def send_file(path, **opts)
    @sent_file = { path: path.to_s, opts: opts }
  end

  def performed?
    !@rendered.nil? || !@sent_file.nil?
  end

  include PersonalAppClient::Rails::SqliteBackup
  sqlite_backup_config prefix: "testapp",
                       extra_files: [ "NOTES.md" ],
                       include_storage: true,
                       wal_checkpoint: true,
                       tables_delete_order: %w[children parents]
end

class FakeMinimalBackupsController < FakeBackupsController
  sqlite_backup_config prefix: "miniapp", list_include_size: false
end

class FakeAbortingBackupsController < FakeBackupsController
  sqlite_backup_config prefix: "testapp",
                       tables_delete_order: %w[children parents]

  private

  def restore_database(_temp_db_path, _zip_path)
    render(json: { error: "Invalid database: missing expected tables" }, status: 422)
  end
end

RSpec.describe PersonalAppClient::Rails::SqliteBackup do
  let(:root)    { Rails.root }
  let(:tmp_dir) { root.join("tmp") }
  let(:db_path) { root.join("db", "app.sqlite3").to_s }
  let(:controller) { FakeBackupsController.new }

  def conn
    ActiveRecord::Base.connection
  end

  before(:each) do
    FileUtils.mkdir_p(tmp_dir)
    FileUtils.mkdir_p(root.join("db"))
    FileUtils.mkdir_p(root.join("storage", "ab"))
    File.write(root.join("NOTES.md"), "original notes")
    File.write(root.join("storage", "ab", "blob1"), "blob-one")
    File.write(root.join("storage", ".keep"), "")

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path)
    conn.execute("CREATE TABLE IF NOT EXISTS parents (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    conn.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS children (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_id INTEGER REFERENCES parents(id),
        label TEXT
      )
    SQL
    conn.execute("DELETE FROM children")
    conn.execute("DELETE FROM parents")
    conn.execute("INSERT INTO parents (id, name) VALUES (1, 'alpha'), (2, 'beta')")
    conn.execute("INSERT INTO children (id, parent_id, label) VALUES (1, 1, 'a1'), (2, 2, 'b1')")

    Dir.glob(tmp_dir.join("*")).each { |f| FileUtils.rm_rf(f) }
  end

  describe "#create_backup" do
    it "zips the db, extra files and storage files, and reports the download URL" do
      controller.create_backup
      json = controller.rendered[:json]

      expect(json[:success]).to be(true)
      expect(json[:filename]).to match(/\Atestapp_backup_\d{8}_\d{6}\.zip\z/)
      expect(json[:download_url]).to eq("/api/backup/download/#{json[:filename]}")

      Zip::File.open(tmp_dir.join(json[:filename]).to_s) do |z|
        expect(z.find_entry("testapp.db")).to be_truthy
        expect(z.find_entry("NOTES.md")).to be_truthy
        expect(z.find_entry("storage_files/ab/blob1")).to be_truthy
        expect(z.find_entry("storage_files/.keep")).to be_nil
      end
    end

    it "prunes to `keep` after writing the new backup" do
      (1..6).each do |i|
        File.write(tmp_dir.join(format("testapp_backup_202401%02d_000000.zip", i)), "x")
      end

      controller.create_backup
      json = controller.rendered[:json]

      remaining = Dir.glob(tmp_dir.join("testapp_backup_*.zip")).map { |p| File.basename(p) }
      expect(remaining.length).to eq(3)
      expect(remaining).to include(json[:filename])
      expect(json[:pruned].length).to eq(4)
    end

    # Regression: tmp/ grew unbounded until the volume filled, at which point
    # wal_checkpoint(TRUNCATE) raised SQLITE_FULL and aborted create_backup
    # before it wrote anything — so a prune placed after the write would never
    # run, and every subsequent night failed the same way. Pruning first is
    # what lets the job recover without someone clearing the disk by hand.
    it "prunes before the WAL checkpoint so a full volume recovers on its own" do
      (1..12).each do |i|
        File.write(tmp_dir.join(format("testapp_backup_202401%02d_000000.zip", i)), "x" * 1000)
      end

      allow(controller).to receive(:checkpoint_wal!) do
        if Dir.glob(tmp_dir.join("testapp_backup_*.zip")).length > 3
          raise ActiveRecord::StatementInvalid, "SQLite3::FullException: database or disk is full"
        end
      end

      controller.create_backup

      expect(controller.rendered[:json][:success]).to be(true)
      expect(Dir.glob(tmp_dir.join("testapp_backup_*.zip")).length).to eq(3)
    end

    it "renders a 500 JSON error when zipping fails" do
      allow(controller).to receive(:write_backup_zip).and_raise("disk full")
      controller.create_backup
      expect(controller.rendered[:status]).to eq(500)
      expect(controller.rendered[:json]).to eq(error: "disk full")
    end
  end

  describe "#prune" do
    # Oldest-first on purpose: prune must pick by the filename timestamp, not
    # by the order the glob happens to return.
    def seed_backups(count, prefix: "testapp")
      (1..count).map do |i|
        name = format("%s_backup_202401%02d_000000.zip", prefix, i)
        File.write(tmp_dir.join(name), "x" * (100 * i))
        name
      end
    end

    it "keeps the newest `keep` backups and deletes the rest" do
      seed_backups(6)

      controller.prune
      json = controller.rendered[:json]

      expect(json[:success]).to be(true)
      expect(json[:kept]).to eq(3)
      expect(json[:pruned].map { |p| p[:filename] }).to eq(
        %w[
          testapp_backup_20240103_000000.zip
          testapp_backup_20240102_000000.zip
          testapp_backup_20240101_000000.zip
        ]
      )
      expect(json[:bytes_freed]).to eq(300 + 200 + 100)
      expect(Dir.glob(tmp_dir.join("testapp_backup_*.zip")).length).to eq(3)
    end

    it "honours an explicit keep param" do
      seed_backups(6)
      controller.params = { keep: "1" }

      controller.prune

      expect(controller.rendered[:json][:kept]).to eq(1)
      expect(Dir.glob(tmp_dir.join("testapp_backup_*.zip")).length).to eq(1)
    end

    it "rejects keep below 1 rather than deleting every backup" do
      seed_backups(3)
      controller.params = { keep: "0" }

      controller.prune

      expect(controller.rendered[:status]).to eq(400)
      expect(Dir.glob(tmp_dir.join("testapp_backup_*.zip")).length).to eq(3)
    end

    it "falls back to a safe floor when the controller config predates :keep" do
      seed_backups(5)
      allow(controller).to receive(:backup_option).and_call_original
      allow(controller).to receive(:backup_option).with(:keep).and_return(nil)

      controller.prune

      expect(Dir.glob(tmp_dir.join("testapp_backup_*.zip")).length).to eq(3)
    end

    it "leaves another app's backups and unrelated tmp files alone" do
      seed_backups(5)
      seed_backups(5, prefix: "miniapp")
      File.write(tmp_dir.join("testapp_backup_notatimestamp.zip"), "keep me")

      controller.prune

      expect(Dir.glob(tmp_dir.join("testapp_backup_2*.zip")).length).to eq(3)
      expect(Dir.glob(tmp_dir.join("miniapp_backup_*.zip")).length).to eq(5)
      expect(File.exist?(tmp_dir.join("testapp_backup_notatimestamp.zip"))).to be(true)
    end
  end

  describe "#list" do
    it "lists backups newest-first with size keys" do
      File.write(tmp_dir.join("testapp_backup_20240101_000000.zip"), "aa")
      File.write(tmp_dir.join("testapp_backup_20240102_000000.zip"), "bbbb")

      controller.list
      entries = controller.rendered[:json]

      expect(entries.length).to eq(2)
      expect(entries.first.keys).to eq(%i[filename size size_mb created download_url])
      expect(entries.first[:size]).to be_a(Integer)
    end

    it "omits the raw size key when list_include_size is false" do
      File.write(tmp_dir.join("miniapp_backup_20240101_000000.zip"), "aa")
      mini = FakeMinimalBackupsController.new
      mini.list
      expect(mini.rendered[:json].first.keys).to eq(%i[filename size_mb created download_url])
    end
  end

  describe "#download" do
    it "rejects filenames that do not match the pattern" do
      controller.params = { filename: "../../etc/passwd" }
      controller.download
      expect(controller.rendered[:status]).to eq(400)
      expect(controller.rendered[:json]).to eq(error: "Invalid filename")
    end

    it "404s for missing files" do
      controller.params = { filename: "testapp_backup_20240101_000000.zip" }
      controller.download
      expect(controller.rendered[:status]).to eq(404)
      expect(controller.rendered[:json]).to eq(error: "File not found")
    end

    it "sends existing backups as attachments" do
      File.write(tmp_dir.join("testapp_backup_20240101_000000.zip"), "zip!")
      controller.params = { filename: "testapp_backup_20240101_000000.zip" }
      controller.download
      expect(controller.sent_file[:opts]).to eq(
        type: "application/zip", disposition: "attachment",
        filename: "testapp_backup_20240101_000000.zip"
      )
    end
  end

  describe "#restore" do
    def create_named_backup(name)
      controller.create_backup
      created = controller.rendered[:json][:filename]
      FileUtils.mv(tmp_dir.join(created), tmp_dir.join(name))
      FakeBackupsController.new
    end

    it "rejects filenames that do not match the pattern" do
      controller.params = { filename: "nope.zip" }
      controller.restore
      expect(controller.rendered[:status]).to eq(400)
    end

    it "404s when the named backup does not exist" do
      controller.params = { filename: "testapp_backup_20240101_000000.zip" }
      controller.restore
      expect(controller.rendered[:status]).to eq(404)
      expect(controller.rendered[:json]).to eq(error: "Backup file not found")
    end

    it "restores rows, sequences, extra files and storage files from the backup" do
      backup_name = "testapp_backup_20200101_000000.zip"
      restorer = create_named_backup(backup_name)

      # Mutate current state
      conn.execute("DELETE FROM children")
      conn.execute("DELETE FROM parents")
      conn.execute("INSERT INTO parents (id, name) VALUES (9, 'gamma')")
      File.write(root.join("NOTES.md"), "mutated notes")
      File.write(root.join("storage", "ab", "blob1"), "mutated blob")

      restorer.params = { filename: backup_name }
      restorer.restore

      json = restorer.rendered[:json]
      expect(json[:success]).to be(true)
      expect(json[:message]).to eq("Database restored successfully")
      expect(json[:safety_backup]).to match(/\Atestapp_backup_\d{8}_\d{6}\.zip\z/)
      expect(File.exist?(tmp_dir.join(json[:safety_backup]))).to be(true)

      expect(conn.select_value("SELECT COUNT(*) FROM parents")).to eq(2)
      names = conn.execute("SELECT name FROM parents ORDER BY id").map { |r| r["name"] }
      expect(names).to eq(%w[alpha beta])
      expect(conn.select_value("SELECT COUNT(*) FROM children")).to eq(2)

      seq = conn.select_value("SELECT seq FROM sqlite_sequence WHERE name = 'parents'")
      expect(seq).to eq(2)

      expect(File.read(root.join("NOTES.md"))).to eq("original notes")
      expect(File.read(root.join("storage", "ab", "blob1"))).to eq("blob-one")

      expect(conn.select_value("PRAGMA foreign_keys")).to eq(1)
      expect(File.exist?(tmp_dir.join(backup_name))).to be(true) # named backups are kept
    end

    it "tolerates schema drift by copying only shared columns" do
      backup_name = "testapp_backup_20200101_000000.zip"

      # Build a backup whose children table lacks the label column
      drift_db = tmp_dir.join("drift.sqlite3").to_s
      drift = SQLite3::Database.new(drift_db)
      drift.execute("CREATE TABLE parents (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
      drift.execute("CREATE TABLE children (id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER)")
      drift.execute("INSERT INTO parents (id, name) VALUES (5, 'drifted')")
      drift.execute("INSERT INTO children (id, parent_id) VALUES (7, 5)")
      drift.close

      Zip::File.open(tmp_dir.join(backup_name).to_s, create: true) do |z|
        z.add("testapp.db", drift_db)
      end

      controller.params = { filename: backup_name }
      controller.restore

      expect(controller.rendered[:json][:success]).to be(true)
      expect(conn.select_value("SELECT name FROM parents WHERE id = 5")).to eq("drifted")
      row = conn.execute("SELECT * FROM children").first
      expect(row["id"]).to eq(7)
      expect(row["label"]).to be_nil
    end

    it "renders Restore failed and re-enables foreign keys when the copy blows up" do
      backup_name = "testapp_backup_20200101_000000.zip"
      restorer = create_named_backup(backup_name)

      allow(restorer).to receive(:restore_database).and_raise("kaput")
      restorer.params = { filename: backup_name }
      restorer.restore

      expect(restorer.rendered[:status]).to eq(500)
      expect(restorer.rendered[:json]).to eq(error: "Restore failed: kaput")
      expect(conn.select_value("PRAGMA foreign_keys")).to eq(1)
      expect(Dir.glob(tmp_dir.join("restore_*.sqlite3"))).to be_empty
    end

    it "skips the shared success render when restore_database already rendered (app hook abort)" do
      backup_name = "testapp_backup_20200101_000000.zip"
      create_named_backup(backup_name)

      aborter = FakeAbortingBackupsController.new
      aborter.params = { filename: backup_name }
      aborter.restore

      expect(aborter.rendered[:status]).to eq(422)
      expect(aborter.rendered[:json]).to eq(error: "Invalid database: missing expected tables")
    end
  end

  describe "restoring every table" do
    def zip_db(db_file, name)
      Zip::File.open(tmp_dir.join(name).to_s, create: true) { |z| z.add("testapp.db", db_file) }
      name
    end

    def create_named_backup(name)
      controller.create_backup
      FileUtils.mv(tmp_dir.join(controller.rendered[:json][:filename]), tmp_dir.join(name))
      FakeBackupsController.new
    end

    after do
      %w[extras parent_tags uuid_things skipped].each { |t| conn.execute("DROP TABLE IF EXISTS #{t}") }
    end

    # Regression: restore only copied tables named in tables_delete_order, so
    # a table added to the schema but not to that list came back empty (or
    # kept whatever the live db held) without any error.
    it "restores a table that is missing from tables_delete_order" do
      conn.execute("CREATE TABLE extras (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT)")
      conn.execute("INSERT INTO extras (id, note) VALUES (4, 'kept')")
      backup_name = "testapp_backup_20200101_000000.zip"
      restorer = create_named_backup(backup_name)

      conn.execute("DELETE FROM extras")
      conn.execute("INSERT INTO extras (id, note) VALUES (11, 'stray')")

      restorer.params = { filename: backup_name }
      restorer.restore

      expect(restorer.rendered[:json][:success]).to be(true)
      rows = conn.execute("SELECT id, note FROM extras").map { |r| [ r["id"], r["note"] ] }
      expect(rows).to eq([ [ 4, "kept" ] ])
      expect(conn.select_value("SELECT seq FROM sqlite_sequence WHERE name = 'extras'")).to eq(4)
    end

    it "restores tables with no id column or a non-integer id without touching sequences" do
      conn.execute("CREATE TABLE parent_tags (parent_id INTEGER, tag TEXT)")
      conn.execute("CREATE TABLE uuid_things (id TEXT PRIMARY KEY, label TEXT)")
      conn.execute("INSERT INTO parent_tags VALUES (1, 'red'), (2, 'blue')")
      conn.execute("INSERT INTO uuid_things VALUES ('b3c1', 'one')")
      backup_name = "testapp_backup_20200101_000000.zip"
      restorer = create_named_backup(backup_name)

      conn.execute("DELETE FROM parent_tags")
      conn.execute("DELETE FROM uuid_things")

      restorer.params = { filename: backup_name }
      restorer.restore

      expect(restorer.rendered[:json][:success]).to be(true)
      expect(conn.select_value("SELECT COUNT(*) FROM parent_tags")).to eq(2)
      expect(conn.select_value("SELECT label FROM uuid_things WHERE id = 'b3c1'")).to eq("one")
      expect(conn.select_value("SELECT COUNT(*) FROM sqlite_sequence WHERE name IN ('parent_tags', 'uuid_things')")).to eq(0)
    end

    it "leaves exclude_tables alone" do
      conn.execute("CREATE TABLE skipped (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT)")
      conn.execute("INSERT INTO skipped (note) VALUES ('in backup')")
      backup_name = "testapp_backup_20200101_000000.zip"
      create_named_backup(backup_name)
      conn.execute("UPDATE skipped SET note = 'live'")

      klass = Class.new(FakeBackupsController)
      klass.sqlite_backup_config prefix: "testapp", exclude_tables: %w[skipped]
      restorer = klass.new
      restorer.params = { filename: backup_name }
      restorer.restore

      expect(restorer.rendered[:json][:success]).to be(true)
      expect(conn.select_value("SELECT note FROM skipped")).to eq("live")
    end

    it "needs no tables_delete_order at all, even with foreign keys between tables" do
      backup_name = "testapp_backup_20200101_000000.zip"
      create_named_backup(backup_name)
      conn.execute("DELETE FROM children")
      conn.execute("DELETE FROM parents")

      klass = Class.new(FakeBackupsController)
      klass.sqlite_backup_config prefix: "testapp"
      restorer = klass.new
      restorer.params = { filename: backup_name }
      restorer.restore

      expect(restorer.rendered[:json][:success]).to be(true)
      expect(conn.select_value("SELECT COUNT(*) FROM parents")).to eq(2)
      expect(conn.select_value("SELECT COUNT(*) FROM children")).to eq(2)
      expect(conn.select_value("PRAGMA foreign_keys")).to eq(1)
    end

    it "does not touch a live table the backup does not have" do
      backup_name = "testapp_backup_20200101_000000.zip"
      create_named_backup(backup_name)
      conn.execute("CREATE TABLE extras (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT)")
      conn.execute("INSERT INTO extras (note) VALUES ('newer than the backup')")

      restorer = FakeBackupsController.new
      restorer.params = { filename: backup_name }
      restorer.restore

      expect(restorer.rendered[:json][:success]).to be(true)
      expect(conn.select_value("SELECT COUNT(*) FROM extras")).to eq(1)
    end

    it "restores into a database that has no sqlite_sequence table" do
      plain_db = root.join("db", "plain.sqlite3").to_s
      FileUtils.rm_f(plain_db)
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: plain_db)
      conn.execute("CREATE TABLE things (id INTEGER PRIMARY KEY, name TEXT)")
      conn.execute("INSERT INTO things VALUES (1, 'live')")

      source_db = tmp_dir.join("plain_source.sqlite3").to_s
      source = SQLite3::Database.new(source_db)
      source.execute("CREATE TABLE things (id INTEGER PRIMARY KEY, name TEXT)")
      source.execute("INSERT INTO things VALUES (8, 'from backup')")
      source.close
      backup_name = zip_db(source_db, "testapp_backup_20200101_000000.zip")

      restorer = FakeBackupsController.new
      restorer.params = { filename: backup_name }
      restorer.restore

      expect(restorer.rendered[:json][:success]).to be(true)
      expect(conn.execute("SELECT id, name FROM things").map { |r| [ r["id"], r["name"] ] })
        .to eq([ [ 8, "from backup" ] ])
    ensure
      ActiveRecord::Base.connection_pool.disconnect!
      FileUtils.rm_f(plain_db)
    end
  end

  describe "defaults" do
    it "checkpoints the WAL unless told otherwise" do
      klass = Class.new(FakeBackupsController)
      klass.sqlite_backup_config prefix: "testapp"
      expect(klass.sqlite_backup_options[:wal_checkpoint]).to be(true)

      c = klass.new
      expect(c).to receive(:checkpoint_wal!).and_call_original
      c.create_backup
      expect(c.rendered[:json][:success]).to be(true)
    end
  end

  describe "operator auth" do
    it "guards every action with OperatorAuth" do
      expect(FakeBackupsController.ancestors).to include(PersonalAppClient::Rails::OperatorAuth)
      expect(FakeBackupsController.before_actions).to include(:authenticate_operator!)
    end

    it "is not enforced outside production" do
      controller.send(:authenticate_operator!)
      expect(controller.rendered).to be_nil
    end

    it "rejects an unauthenticated request in production" do
      with_rails_env("production") do
        controller.send(:authenticate_operator!)
        expect(controller.rendered).to eq(json: { error: "unauthorized" }, status: :unauthorized)
      end
    end
  end

  describe "#restore_upload" do
    it "400s without a file" do
      controller.restore_upload
      expect(controller.rendered[:status]).to eq(400)
      expect(controller.rendered[:json]).to eq(error: "No file uploaded")
    end

    it "400s for non-zip uploads" do
      controller.params = { file: OpenStruct.new(original_filename: "backup.tar") }
      controller.restore_upload
      expect(controller.rendered[:status]).to eq(400)
      expect(controller.rendered[:json]).to eq(error: "File must be a .zip archive")
    end

    it "422s when the ZIP lacks the db entry, and cleans up the temp copy" do
      bogus = tmp_dir.join("upload-src.zip").to_s
      Zip::File.open(bogus, create: true) { |z| z.get_output_stream("other.txt") { |f| f.write "x" } }

      controller.params = { file: OpenStruct.new(original_filename: "b.zip", tempfile: File.open(bogus)) }
      controller.restore_upload

      expect(controller.rendered[:status]).to eq(422)
      expect(controller.rendered[:json]).to eq(error: "Invalid backup: missing testapp.db")
      expect(Dir.glob(tmp_dir.join("restore_upload_*.zip"))).to be_empty
    end

    it "restores from an uploaded backup" do
      controller.create_backup
      created = controller.rendered[:json][:filename]
      src = tmp_dir.join("upload-src.zip").to_s
      FileUtils.mv(tmp_dir.join(created), src)

      conn.execute("DELETE FROM children")
      conn.execute("DELETE FROM parents")

      uploader = FakeBackupsController.new
      uploader.params = { file: OpenStruct.new(original_filename: "b.zip", tempfile: File.open(src)) }
      uploader.restore_upload

      expect(uploader.rendered[:json][:success]).to be(true)
      expect(conn.select_value("SELECT COUNT(*) FROM parents")).to eq(2)
      expect(Dir.glob(tmp_dir.join("restore_upload_*.zip"))).to be_empty
    end
  end

  describe "source_db_path option" do
    it "uses the configured proc for create_backup's db file" do
      other_db = root.join("db", "other.sqlite3").to_s
      SQLite3::Database.new(other_db).tap { |d| d.execute("CREATE TABLE t (id INTEGER)"); d.close }

      klass = Class.new(FakeBackupsController)
      klass.sqlite_backup_config prefix: "srcapp", source_db_path: -> { ::Rails.root.join("db", "other.sqlite3") }
      c = klass.new
      c.create_backup

      filename = c.rendered[:json][:filename]
      Zip::File.open(tmp_dir.join(filename).to_s) do |z|
        expect(z.find_entry("srcapp.db")).to be_truthy
      end
    end
  end
end
