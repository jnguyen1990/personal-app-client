module PersonalAppClient
  # Default GET /api/health/inter-app (HealthCheck). Targets come from
  # config.health_targets, a Proc run in this controller so it can use the
  # probe helpers:
  #
  #     app.health_targets = -> { [ probe_client("base", BaseAppClient.new) ] }
  #
  # No Proc means no outbound targets (budgeter). base, whose controller
  # also serves /api/health/cluster, keeps its own: `health: "api/health"`.
  class HealthController < PersonalAppClient.api_base_controller
    include PersonalAppClient::Rails::HealthCheck

    private

    def health_targets
      targets = PersonalAppClient.config.health_targets
      targets ? Array(instance_exec(&targets)) : []
    end
  end
end
