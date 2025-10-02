defmodule CorroPort.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
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
