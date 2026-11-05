module PersonalAppClient
  class << self
    # The deployed git SHA, or nil when it cannot be determined. Memoized for
    # the life of the process (a deploy restarts the app). Reads a REVISION
    # file at the app root if the deploy wrote one, else follows .git/HEAD to
    # the ref file (or packed-refs) with plain file reads — no subprocess, so
    # it works where git is not installed and costs nothing per request.
    def revision(root = nil)
      return @revision if defined?(@revision) && root.nil?
      sha = read_revision(root || default_revision_root)
      @revision = sha if root.nil?
      sha
    end

    # For specs, and for anything that swaps the checkout under a live process.
    def reset_revision!
      remove_instance_variable(:@revision) if defined?(@revision)
    end

    private

    def default_revision_root
      defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : Dir.pwd
    end

    def read_revision(root)
      root = root.to_s
      from_file = read_first_line(File.join(root, "REVISION"))
      return from_file if from_file

      git_dir = resolve_git_dir(File.join(root, ".git"))
      return nil unless git_dir

      head = read_first_line(File.join(git_dir, "HEAD"))
      return nil unless head
      return head unless head.start_with?("ref:") # detached HEAD holds the SHA

      ref = head.sub(/\Aref:\s*/, "")
      # In a linked worktree refs live in the main repository's git dir.
      common = read_first_line(File.join(git_dir, "commondir"))
      refs_dir = common ? File.expand_path(common, git_dir) : git_dir
      read_first_line(File.join(refs_dir, ref)) || packed_ref(refs_dir, ref)
    rescue SystemCallError
      nil
    end

    # `.git` is a directory in a normal clone and a "gitdir: <path>" file in
    # a worktree or submodule.
    def resolve_git_dir(path)
      return path if File.directory?(path)
      pointer = read_first_line(path)
      return nil unless pointer&.start_with?("gitdir:")
      File.expand_path(pointer.sub(/\Agitdir:\s*/, ""), File.dirname(path))
    end

    def packed_ref(git_dir, ref)
      path = File.join(git_dir, "packed-refs")
      return nil unless File.file?(path)
      File.foreach(path) do |line|
        sha, name = line.strip.split(" ", 2)
        return sha if name == ref
      end
      nil
    end

    def read_first_line(path)
      return nil unless File.file?(path)
      line = File.open(path, &:gets).to_s.strip
      line.empty? ? nil : line
    end
  end
end
