defmodule CorroPort.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Dev clustering helper (only in dev)
    # Use config value instead of Mix.env() which isn't available in releases
    dev_cluster =
      if Application.get_env(:corro_port, :dev_routes, false) do
        [CorroPort.DevClusterConnector]
      else
        []
      end

    children =
      dev_cluster ++
        [
          CorroPortWeb.Telemetry,
          {DNSCluster, query: Application.get_env(:corro_port, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: CorroPort.PubSub},
          {Finch,
           name: WhereCorro.Finch,
           pools: %{
             default: [conn_opts: [transport_opts: [inet6: true]]]
           }},

          # Core data services (legacy - kept for compatibility)
          CorroPort.CorroSubscriber,
          # ConfigSubscriber removed - now using PubSub-based ClusterConfigCoordinator
          CorroPort.NodeIdentityReporter,
          CorroPort.ClusterConfigCoordinator,
          CorroPort.AckTracker,
          CorroPort.AckSender,
          CorroPort.CLIClusterData,

          # Analytics modules
          CorroPort.Analytics.Repo,
          CorroPort.AnalyticsStorage,
          CorroPort.SystemMetrics,
          CorroPort.AnalyticsAggregator,

          # Web endpoints
          CorroPortWeb.Endpoint,
          CorroPortWeb.APIEndpoint
        ]

    opts = [strategy: :one_for_one, name: CorroPort.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CorroPortWeb.Endpoint.config_change(changed, removed)
    CorroPortWeb.APIEndpoint.config_change(changed, removed)
    :ok
  end
end
