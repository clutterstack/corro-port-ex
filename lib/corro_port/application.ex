defmodule CorroPort.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
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
      # Add the CorroSubscriber to subscribe to Corrosion changes
      CorroPort.CorroSubscriber,
      CorroPort.AckTracker,
      CorroPort.AckSender,
      # Start to serve requests, typically the last entry
      CorroPortWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: CorroPort.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CorroPortWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
