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
    case System.cmd("pkill", ["-f", "corrosion"], stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Stopped Corrosion processes")

      {_output, 1} ->
        Mix.shell().info("No Corrosion processes found")

      {output, exit_code} ->
        Mix.shell().info("pkill exited with code #{exit_code}: #{output}")
    end

    # Give processes time to shut down
    Process.sleep(1000)
  end

  defp cleanup_files do
    files_to_clean = [
      "corrosion/node*.db*",
      "corrosion/config-node*.toml",
      "/tmp/corrosion/node*_admin.sock"
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

    # Clean up admin socket directory if empty
    case File.ls("/tmp/corrosion") do
      {:ok, []} ->
        File.rmdir("/tmp/corrosion")
        Mix.shell().info("Removed empty /tmp/corrosion directory")
      _ ->
        :ok
    end
  end
end
