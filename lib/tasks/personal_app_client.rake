namespace :personal_app do
  namespace :ds do
    desc "Copy the design system into public/ds/ (the shell's offline fallback). DS_BASE overrides the source."
    task snapshot: :environment do
      files = PersonalAppClient::DsSnapshot.run!(dest: Rails.root.join("public", "ds"), logger: Rails.logger)
      puts "public/ds: #{files.size} files from #{PersonalAppClient.config.ds_base}"
    rescue StandardError => e
      # A deploy must not fail because the CDN is down — that is exactly when
      # the previous snapshot is needed.
      warn "personal_app:ds:snapshot failed (previous snapshot kept): #{e.message}"
    end
  end
end
