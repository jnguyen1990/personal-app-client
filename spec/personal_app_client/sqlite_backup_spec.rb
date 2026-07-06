require "ostruct"
require "tmpdir"
require "pathname"
require "active_record"
require "zip"
require "personal_app_client/rails/sqlite_backup"

# Minimal Rails stand-in — the backup concern only touches ::Rails.root.
module Rails
  def self.root
    @root ||= Pathname.new(Dir.mktmpdir("pac_sqlite_backup"))
  end
end

class FakeBackupsController
  attr_accessor :params
  attr_reader :rendered, :sent_file

  def initialize
    @params = {}
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

    it "renders a 500 JSON error when zipping fails" do
      allow(controller).to receive(:write_backup_zip).and_raise("disk full")
      controller.create_backup
      expect(controller.rendered[:status]).to eq(500)
      expect(controller.rendered[:json]).to eq(error: "disk full")
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
