require "tmpdir"
require "fileutils"

RSpec.describe "PersonalAppClient.revision" do
  let(:root) { Dir.mktmpdir("pac_revision") }
  let(:sha)  { "0123456789abcdef0123456789abcdef01234567" }

  after do
    FileUtils.rm_rf(root)
    PersonalAppClient.reset_revision!
  end

  def write(path, content)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  it "prefers a REVISION file" do
    write("REVISION", "#{sha}\n")
    write(".git/HEAD", "ref: refs/heads/main\n")
    expect(PersonalAppClient.revision(root)).to eq(sha)
  end

  it "follows .git/HEAD to a loose ref" do
    write(".git/HEAD", "ref: refs/heads/main\n")
    write(".git/refs/heads/main", "#{sha}\n")
    expect(PersonalAppClient.revision(root)).to eq(sha)
  end

  it "falls back to packed-refs" do
    write(".git/HEAD", "ref: refs/heads/main\n")
    write(".git/packed-refs", "# pack-refs with: peeled fully-peeled sorted\n" \
                              "ffffffffffffffffffffffffffffffffffffffff refs/heads/other\n" \
                              "#{sha} refs/heads/main\n")
    expect(PersonalAppClient.revision(root)).to eq(sha)
  end

  it "returns the SHA of a detached HEAD" do
    write(".git/HEAD", "#{sha}\n")
    expect(PersonalAppClient.revision(root)).to eq(sha)
  end

  it "follows a gitdir pointer file (worktree)" do
    write("main/.git/HEAD", "ref: refs/heads/main\n")
    write("main/.git/refs/heads/topic", "#{sha}\n")
    write("main/.git/worktrees/wt/HEAD", "ref: refs/heads/topic\n")
    write("main/.git/worktrees/wt/commondir", "../..\n")
    write("wt/.git", "gitdir: ../main/.git/worktrees/wt\n")
    expect(PersonalAppClient.revision(File.join(root, "wt"))).to eq(sha)
  end

  it "is nil when there is nothing to read" do
    expect(PersonalAppClient.revision(root)).to be_nil
  end

  it "is nil when the ref cannot be resolved" do
    write(".git/HEAD", "ref: refs/heads/gone\n")
    expect(PersonalAppClient.revision(root)).to be_nil
  end

  it "never shells out" do
    write(".git/HEAD", "#{sha}\n")
    expect(Kernel).not_to receive(:system)
    expect(PersonalAppClient).not_to receive(:`)
    PersonalAppClient.revision(root)
  end

  it "memoizes the default lookup for the life of the process" do
    PersonalAppClient.reset_revision!
    allow(PersonalAppClient).to receive(:default_revision_root).and_return(root)
    write("REVISION", sha)
    expect(PersonalAppClient.revision).to eq(sha)

    write("REVISION", "changed")
    expect(PersonalAppClient.revision).to eq(sha)

    PersonalAppClient.reset_revision!
    expect(PersonalAppClient.revision).to eq("changed")
  end
end
