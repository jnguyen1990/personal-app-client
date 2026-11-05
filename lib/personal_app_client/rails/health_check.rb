require "active_support/concern"
require "active_support/core_ext/time/calculations"
require "active_support/core_ext/time/zones"
require_relative "../errors"
require_relative "../revision"

module PersonalAppClient
  module Rails
    # The inter-app health endpoint every app exposes at
    # GET /api/health/inter-app (base aggregates them at /api/health/cluster).
    #
    #     class Api::HealthController < BaseController
    #       include PersonalAppClient::Rails::HealthCheck
    #
    #       private
    #
    #       # One entry per outbound service this app calls. Default: none.
    #       def health_targets
    #         [ probe_client("base", BaseAppClient.new),
    #           probe("weather", url) { WeatherApi.fetch! } ]
    #       end
    #     end
    #
    # Response: { ok:, checked_at:, revision:, targets: [ … ] } — `ok` is false
    # only when a target is in "error" ("unconfigured" is not an error), and
    # `revision` is the deployed git SHA (PersonalAppClient.revision).
    module HealthCheck
      extend ActiveSupport::Concern

      def inter_app
        render json: health_payload(health_targets)
      end

      private

      # Override to list this app's outbound targets, built with `probe` /
      # `unconfigured`.
      def health_targets
        []
      end

      # The response body for a set of targets — exposed separately so a
      # richer controller (base's cluster view) can reuse the shape.
      def health_payload(targets)
        {
          ok: targets.all? { |t| t[:status] != "error" },
          checked_at: Time.current.iso8601,
          revision: PersonalAppClient.revision,
          targets: targets
        }
      end

      # Time the block; "ok" with latency if it returns, "error" if it raises.
      def probe(name, url)
        start = Time.current
        yield
        { name: name, url: url, status: "ok",
          latency_ms: ((Time.current - start) * 1000).round }
      rescue PersonalAppClient::Error => e
        { name: name, url: url, status: "error", error: e.message }
      rescue => e
        { name: name, url: url, status: "error", error: "#{e.class}: #{e.message}" }
      end

      def unconfigured(name, url)
        { name: name, url: url, status: "unconfigured" }
      end

      # Probe a PersonalAppClient::AppClient (HubClient, FitnessAppClient, …)
      # by GETting `path` through it: "unconfigured" when it has no URL,
      # otherwise "ok" / "error" as `probe` reports them.
      def probe_client(name, client, path = "/up")
        return unconfigured(name, client.base_url) unless client.configured?

        probe(name, client.base_url) do
          result = client.ping(path)
          raise PersonalAppClient::Error, result[:error].to_s unless result[:success]
        end
      end
    end
  end
end
