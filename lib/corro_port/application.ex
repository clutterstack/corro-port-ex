defmodule CorroPort.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Start Corrosion before our stuff. Let it do its own stdin/stout
    {:ok, config_file} = CorroPort.NodeConfig.write_corrosion_config()
    corro_binary = Application.get_env(:corro_port, :node_config)[:corrosion_binary]
    corrosion_cmd = "#{corro_binary} agent -c #{config_file}"

    case :exec.run_link(corrosion_cmd, [{:stdout, :print}, {:stderr, :print}]) do
      {:ok, _exec_pid, _os_pid} ->
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
          # Start a worker by calling: CorroPort.Worker.start_link(arg)
          # {CorroPort.Worker, arg},
          # Start to serve requests, typically the last entry
          CorroPortWeb.Endpoint
        ]

        opts = [strategy: :one_for_one, name: CorroPort.Supervisor]
        Supervisor.start_link(children, opts)

      {:error, reason} ->
        raise "Failed to start corrosion agent: #{inspect(reason)}"
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CorroPortWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
