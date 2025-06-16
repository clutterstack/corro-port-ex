defmodule Mix.Tasks.Cluster.Start do
  @moduledoc """
  Mix tasks for managing local Corrosion clusters using external scripts.

  ## Start a cluster

      mix cluster.start

  Starts a 3-node cluster using the development startup script.

  ## Start a specific number of nodes

      mix cluster.start --nodes 5

  ## Start with verbose output

      mix cluster.start --verbose
  """

  use Mix.Task

  @shortdoc "Starts a Corrosion development cluster using scripts"

  def run(args) do
    {parsed, _, _} =
      OptionParser.parse(args,
        switches: [nodes: :integer, verbose: :boolean, help: :boolean],
        aliases: [n: :nodes, v: :verbose, h: :help]
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
    verbose = opts[:verbose] || false

    Mix.shell().info("Starting #{num_nodes}-node CorroPort cluster...")

    # Check if the script exists
    script_path = "scripts/dev-cluster.sh"

    unless File.exists?(script_path) do
      Mix.shell().error("Cluster script not found: #{script_path}")
      Mix.shell().error("Please ensure the development scripts are available.")
      exit(1)
    end

    # Make script executable
    case System.cmd("chmod", ["+x", script_path]) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        Mix.shell().error("Failed to make script executable: #{output} (exit: #{exit_code})")
        exit(1)
    end

    # Build command arguments
    args = ["--nodes", "#{num_nodes}"]
    args = if verbose, do: args ++ ["--verbose"], else: args

    Mix.shell().info("Running: #{script_path} #{Enum.join(args, " ")}")

    # Execute the script
    case System.cmd(script_path, args, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        Mix.shell().info("Cluster stopped successfully")

      {_, exit_code} ->
        Mix.shell().error("Cluster script exited with code #{exit_code}")
        exit(exit_code)
    end
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end

defmodule Mix.Tasks.Cluster.Stop do
  @moduledoc """
  Stops all Corrosion processes and cleans up cluster files.

  ## Usage

      mix cluster.stop

  This will:
  - Kill any running Corrosion processes
  - Clean up temporary files
  - Remove generated config files
  """

  use Mix.Task

  @shortdoc "Stops the Corrosion cluster and cleans up"

  def run(_args) do
    Mix.shell().info("Stopping Corrosion cluster...")

    # Kill any corrosion processes
    stop_corrosion_processes()

    # Clean up files
    cleanup_files()

    Mix.shell().info("Cluster stopped and cleaned up.")
  end

  defp stop_corrosion_processes do
    case System.cmd("pkill", ["-f", "corrosion.*agent"], stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Stopped Corrosion processes")

      {_output, 1} ->
        Mix.shell().info("No Corrosion processes found")

      {output, exit_code} ->
        Mix.shell().info("pkill exited with code #{exit_code}: #{output}")
    end

    # Kill any overmind processes
    case System.cmd("pkill", ["-f", "overmind"], stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Stopped Overmind processes")

      {_output, 1} ->
        # No overmind processes found
        :ok

      {output, exit_code} ->
        Mix.shell().info("pkill overmind exited with code #{exit_code}: #{output}")
    end

    # Give processes time to shut down
    Process.sleep(1000)
  end

  defp cleanup_files do
    files_to_clean = [
      "corrosion/node*.db*",
      "corrosion/config-node*.toml",
      "/tmp/corrosion/node*_admin.sock",
      "logs/node*.log"
    ]

    for pattern <- files_to_clean do
      case Path.wildcard(pattern) do
        [] ->
          :ok

        files ->
          Mix.shell().info("Cleaning up: #{Enum.join(files, ", ")}")
          Enum.each(files, &File.rm/1)
      end
    end

    # Clean up directories if empty
    Enum.each(["/tmp/corrosion", "logs"], fn dir ->
      case File.ls(dir) do
        {:ok, []} ->
          File.rmdir(dir)
          Mix.shell().info("Removed empty directory: #{dir}")

        _ ->
          :ok
      end
    end)
  end
end
