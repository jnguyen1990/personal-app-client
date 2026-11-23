require "net/http"
require "uri"
require "fileutils"
require_relative "configuration"

module PersonalAppClient
  # Copies the design system into public/ds/ so the shell has a local
  # fallback when the CDN is down (`bin/rails personal_app:ds:snapshot`, run
  # from bin/deploy). Fetches Configuration::DS_FILES plus any relative
  # url(...) the stylesheet references (self-hosted fonts). Writes to a temp
  # directory and swaps it in only when every file arrived, so a failed run
  # keeps the previous snapshot.
  module DsSnapshot
    module_function

    def run!(dest:, base: PersonalAppClient.config.ds_base, files: Configuration::DS_FILES,
             fetcher: method(:fetch), logger: nil)
      dest = File.expand_path(dest.to_s)
      staging = "#{dest}.tmp-#{Process.pid}"
      FileUtils.rm_rf(staging)
      FileUtils.mkdir_p(staging)

      queue = files.dup
      written = []
      until queue.empty?
        rel = queue.shift
        next if written.include?(rel)

        body = fetcher.call(URI.join("#{base.chomp('/')}/", rel))
        path = File.join(staging, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, body)
        written << rel
        queue.concat(relative_urls(body, rel)) if rel.end_with?(".css")
      end

      FileUtils.rm_rf(dest)
      FileUtils.mv(staging, dest)
      logger&.info("ds snapshot: #{written.size} files from #{base} into #{dest}")
      written
    ensure
      FileUtils.rm_rf(staging) if staging && File.exist?(staging)
    end

    # Relative url(...) targets in a stylesheet, resolved against its path.
    def relative_urls(css, css_path)
      dir = File.dirname(css_path)
      css.to_s.scan(/url\(\s*['"]?([^'")]+)['"]?\s*\)/).flatten.filter_map do |ref|
        next if ref.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|//|#)}i) # absolute, data:, protocol-relative, fragment
        clean = ref.split(/[?#]/).first
        File.expand_path(clean, "/#{dir}").delete_prefix("/")
      end.uniq
    end

    def fetch(uri, limit = 3)
      response = Net::HTTP.get_response(uri)
      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection
        raise PersonalAppClient::Error, "too many redirects for #{uri}" if limit.zero?
        fetch(URI.join(uri.to_s, response["location"]), limit - 1)
      else
        raise PersonalAppClient::Error, "GET #{uri} → HTTP #{response.code}"
      end
    end
  end
end
