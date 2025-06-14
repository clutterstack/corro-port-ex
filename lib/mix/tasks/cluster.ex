defmodule Mix.Tasks.Cluster.Start do
  @moduledoc """
  Mix tasks for managing local Corrosion clusters.

  ## Start a cluster

      mix cluster.start

  Starts a 3-node cluster with interactive IEx on node 1. (NOT QUITE WORKING RIGHT -- start nodes manually with    NODE_ID=1 iex --sname corro1 -S mix phx.server instead)

  ## Start a specific number of nodes

      mix cluster.start --nodes 5

  ## Start with custom node names

      mix cluster.start --prefix myapp

  This will create nodes named myapp1, myapp2, myapp3, etc.
  """

  use Mix.Task

  @shortdoc "Manages local Corrosion clusters"

  def run(args) do
    {parsed, _, _} =
      OptionParser.parse(args,
        switches: [nodes: :integer, prefix: :string, help: :boolean],
        aliases: [n: :nodes, p: :prefix, h: :help]
      )

    cond do
      parsed[:help] ->
        print_help()

      true ->
        start_cluster(parsed)
    end
  end

  defp start_cluster(opts) do
    num_nodes = opts[:nodes] || 3
    prefix = opts[:prefix] || "corro"

    Mix.shell().info("Starting #{num_nodes}-node Corrosion cluster...")
    Mix.shell().info("Node prefix: #{prefix}")
    Mix.shell().info("")

    # Print startup information
    print_cluster_info(1..num_nodes, prefix)

    if num_nodes == 1 do
      # Just start node 1 in foreground
      Mix.shell().info("Starting single node in foreground with IEx...")
      start_foreground_node(1, prefix)
    else
      # Start nodes 2..N in the background
      background_pids =
        for node_id <- 2..num_nodes do
          start_background_node(node_id, prefix)
        end

      # Give background nodes a moment to start
      Process.sleep(2000)

      # Start node 1 in the foreground with IEx
      Mix.shell().info("Starting node 1 in foreground with IEx...")
      Mix.shell().info("Use Ctrl+C twice to stop the cluster.")
      Mix.shell().info("")

      try do
        start_foreground_node(1, prefix)
      after
        # Clean up background processes when we exit
        Mix.shell().info("Stopping background nodes...")

        Enum.each(background_pids, fn pid ->
          try do
            Process.exit(pid, :kill)
          catch
            _ -> :ok
          end
        end)
      end
    end
  end

  defp start_background_node(node_id, prefix) do
    node_name = "#{prefix}#{node_id}"

    spawn(fn ->
      env = [{"NODE_ID", "#{node_id}"}]
      cmd_args = ["--sname", node_name, "-S", "mix", "phx.server"]

      Mix.shell().info("Starting background node: #{node_name} (NODE_ID=#{node_id})")

      case System.cmd("iex", cmd_args, env: env, stderr_to_stdout: true) do
        {output, 0} ->
          Mix.shell().info("Node #{node_name} exited normally")

        {output, exit_code} ->
          Mix.shell().error("Node #{node_name} exited with code #{exit_code}")

          if String.length(output) > 0 do
            Mix.shell().error("Output: #{output}")
          end
      end
    end)
  end

  defp start_foreground_node(node_id, prefix) do
    node_name = "#{prefix}#{node_id}"

    # Set environment and exec into IEx
    System.put_env("NODE_ID", "#{node_id}")

    # Use System.cmd with inherit stdio to get an interactive shell
    args = ["--sname", node_name, "-S", "mix", "phx.server"]

    case System.find_executable("iex") do
      nil ->
        Mix.shell().error("Could not find 'iex' executable")
        exit(1)

      iex_path ->
        Mix.shell().info("Starting: #{iex_path} #{Enum.join(args, " ")}")

        # Use System.cmd with stdio inheritance for interactive session
        case System.cmd(iex_path, args,
               into: IO.stream(:stdio, :line),
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            Mix.shell().info("Node #{node_name} exited normally")

          {_, exit_code} ->
            Mix.shell().error("Node #{node_name} exited with code #{exit_code}")
        end
    end
  end

  defp print_cluster_info(node_range, prefix) do
    Mix.shell().info("Cluster Information:")
    Mix.shell().info("===================")

    for node_id <- node_range do
      phoenix_port = 4000 + node_id
      api_port = 8080 + node_id
      gossip_port = 8786 + node_id
      node_name = "#{prefix}#{node_id}"

      Mix.shell().info("Node #{node_id} (#{node_name}):")
      Mix.shell().info("  Phoenix:   http://localhost:#{phoenix_port}")
      Mix.shell().info("  Corrosion API: http://localhost:#{api_port}")
      Mix.shell().info("  Corrosion Gossip: localhost:#{gossip_port}")
      Mix.shell().info("")
    end

    Mix.shell().info("Connect to other nodes from IEx:")

    for node_id <- node_range, node_id != 1 do
      node_name = "#{prefix}#{node_id}"
      Mix.shell().info("  Node.connect(:\"#{node_name}@#{get_hostname()}\")")
    end

    Mix.shell().info("")
  end

  defp get_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> hostname
      _ -> "localhost"
    end
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end
