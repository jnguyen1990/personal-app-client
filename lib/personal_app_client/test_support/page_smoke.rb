module PersonalAppClient
  module TestSupport
    # A page-load smoke test for every app (PLAT-52): open each top-level page
    # (the shell's nav_items) in headless Chrome and fail on an error response,
    # an uncaught exception, an unhandled rejection or a console.error — the
    # breakage that until now was only found by using the app.
    #
    #     # test/application_system_test_case.rb
    #     require "test_helper"
    #     require "capybara/cuprite"
    #     class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
    #       driven_by :cuprite, screen_size: [ 1440, 900 ],
    #                 options: PersonalAppClient::TestSupport::PageSmoke.cuprite_options
    #     end
    #
    #     # test/system/smoke_test.rb
    #     require "application_system_test_case"
    #     class SmokeTest < ApplicationSystemTestCase
    #       include PersonalAppClient::TestSupport::PageSmoke
    #       smoke_test_pages                       # every nav_items path
    #       smoke_test_pages "/settings#backup"    # plus any others
    #     end
    #
    # Needs `capybara` and `cuprite` in the test group; Chrome from the
    # system (the CI runner has it; BROWSER_PATH points elsewhere). Pages are
    # rendered against the empty test database, so they must cope with no data.
    module PageSmoke
      # Collects errors from before the first page script runs.
      COLLECTOR = <<~JS.freeze
        (function () {
          var errors = window.__smokeErrors = [];
          var original = console.error;
          console.error = function () {
            try { errors.push('console.error: ' + Array.prototype.map.call(arguments, String).join(' ')); } catch (_) {}
            return original.apply(console, arguments);
          };
          window.addEventListener('error', function (e) {
            errors.push('error: ' + (e.message || (e.target && (e.target.src || e.target.href)) || 'unknown') +
                        (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : ''));
          }, true);
          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason; errors.push('unhandledrejection: ' + (r && r.message ? r.message : String(r)));
          });
        })();
      JS

      # Options for `driven_by :cuprite`. js_errors stays off so an exception
      # is collected and reported with the others instead of raised mid-visit.
      def self.cuprite_options
        { js_errors: false, process_timeout: 30, timeout: 15, headless: true,
          browser_options: { "no-sandbox" => nil } }.tap do |o|
          o[:browser_path] = ENV["BROWSER_PATH"] if ENV["BROWSER_PATH"].present?
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # One test per path; no arguments = every nav_items path.
        def smoke_test_pages(*paths)
          paths = PageSmoke.nav_paths if paths.empty?
          paths.each do |path|
            test("page #{path} loads without errors") { assert_page_loads(path) }
          end
        end
      end

      # The nav paths from PersonalAppClient.config.nav_items (static Arrays only).
      def self.nav_paths
        items = PersonalAppClient.config.nav_items
        items = [] if items.respond_to?(:call)
        items.map { |i| i[:path] || i["path"] }.compact.uniq
      end

      # Errors a page may legitimately log in the test environment.
      IGNORED = [
        /Failed to load resource/i # a sibling app or the CDN unreachable from CI is not this page's bug
      ].freeze

      def assert_page_loads(path, ignore: [])
        page.driver.browser.evaluate_on_new_document(COLLECTOR)
        visit path
        status = page.status_code
        assert status.nil? || status < 400, "#{path} answered HTTP #{status}"
        assert_selector "h1", minimum: 1, wait: 5
        settle_page
        errors = Array(page.evaluate_script("window.__smokeErrors || []"))
        errors.reject! { |e| (IGNORED + Array(ignore)).any? { |re| re.match?(e) } }
        assert errors.empty?, "#{path} logged errors:\n  #{errors.join("\n  ")}"
      end

      private

      # Let the page's own fetches (most pages load their data after
      # DOMContentLoaded) finish and render.
      def settle_page
        network = page.driver.browser.network if page.driver.browser.respond_to?(:network)
        network ? network.wait_for_idle(timeout: 5) : page.driver.wait_for_network_idle(timeout: 5)
      rescue StandardError
        nil
      end
    end
  end
end
