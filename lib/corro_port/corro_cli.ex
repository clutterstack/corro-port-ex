defmodule CorroPort.CorrosionCLI do
  @moduledoc """
  Interface for running Corrosion CLI commands using Elixir Ports.

  Provides functions to execute corrosion commands like `cluster members`,
  `cluster info`, etc. and returns the raw output for further processing.
  """

  require Logger
  alias CorroPort.NodeConfig

  @default_timeout 5_000

  @doc """
  Gets cluster members information using `corrosion cluster members`.

  ## Returns
  - `{:ok, output}` - Raw JSON output from corrosion command
  - `{:error, reason}` - Error with details

  ## Examples
      iex> CorroPort.CorrosionCLI.cluster_members()
      {:ok, "{\\"id\\": \\"94bfbec2...\\"..."}
  """
  def cluster_members(opts \\ []) do
    run_command(["cluster", "members"], opts)
  end

  @doc """
  Gets cluster members information asynchronously.

  ## Returns
  - `Task` that when awaited returns `{:ok, output}` or `{:error, reason}`

  ## Examples
      iex> task = CorroPort.CorrosionCLI.cluster_members_async()
      iex> Task.await(task, 10_000)
      {:ok, "{\\"id\\": \\"94bfbec2...\\"..."}
  """
  def cluster_members_async(opts \\ []) do
    Task.async(fn -> cluster_members(opts) end)
  end

  @doc """
  Gets cluster information using `corrosion cluster info`.
  """
  def cluster_info(opts \\ []) do
    run_command(["cluster", "info"], opts)
  end

  @doc """
  Gets cluster information asynchronously.
  """
  def cluster_info_async(opts \\ []) do
    Task.async(fn -> cluster_info(opts) end)
  end

  @doc """
  Gets cluster status using `corrosion cluster status`.
  """
  def cluster_status(opts \\ []) do
    run_command(["cluster", "status"], opts)
  end

  @doc """
  Gets cluster status asynchronously.
  """
  def cluster_status_async(opts \\ []) do
    Task.async(fn -> cluster_status(opts) end)
  end

  @doc """
  Runs an arbitrary corrosion command with the current node's config.

  ## Parameters
  - `args` - List of command arguments (e.g., ["cluster", "members"])
  - `opts` - Options keyword list
    - `:timeout` - Command timeout in milliseconds (default: 5000)
    - `:config_path` - Override config path (uses NodeConfig.get_config_path/0 by default)
    - `:binary_path` - Override binary path (uses NodeConfig.get_corro_binary_path/0 by default)

  ## Returns
  - `{:ok, output}` - Command output as string
  - `{:error, reason}` - Error details

  ## Examples
      iex> CorroPort.CorrosionCLI.run_command(["cluster", "members"])
      {:ok, "{\\"id\\": \\"94bfbec2..."}

      iex> CorroPort.CorrosionCLI.run_command(["invalid", "command"])
      {:error, {:exit_code, 1, "Error: unknown command..."}}
  """
  def run_command(args, opts \\ []) when is_list(args) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    config_path = Keyword.get(opts, :config_path, NodeConfig.get_config_path())
    binary_path = Keyword.get(opts, :binary_path, NodeConfig.get_corro_binary_path())

    # Build the full command
    cmd_args = args ++ ["--config", config_path]

    Logger.debug("CorrosionCLI: command #{binary_path} #{Enum.join(cmd_args, " ")}")

    # Validate that binary and config exist
    case validate_prerequisites(binary_path, config_path) do
      :ok ->
        execute_port_command(binary_path, cmd_args, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs an arbitrary corrosion command asynchronously.

  ## Parameters
  - `args` - List of command arguments
  - `opts` - Options keyword list (same as run_command/2)

  ## Returns
  - `Task` that when awaited returns `{:ok, output}` or `{:error, reason}`

  ## Examples
      iex> task = CorroPort.CorrosionCLI.run_command_async(["cluster", "members"])
      iex> result = Task.await(task, 10_000)
      {:ok, "{\\"id\\": \\"94bfbec2..."}

      # Run multiple commands concurrently
      iex> tasks = [
      ...>   CorroPort.CorrosionCLI.cluster_members_async(),
      ...>   CorroPort.CorrosionCLI.cluster_info_async(),
      ...>   CorroPort.CorrosionCLI.cluster_status_async()
      ...> ]
      iex> results = Task.await_many(tasks, 10_000)
  """
  def run_command_async(args, opts \\ []) when is_list(args) do
    Task.async(fn -> run_command(args, opts) end)
  end

  # Private functions

  defp validate_prerequisites(binary_path, config_path) do
    abs_binary_path = Path.absname(binary_path)
    abs_config_path = Path.absname(config_path)

    cond do
      not File.exists?(abs_binary_path) ->
        Logger.error("CorrosionCLI: Binary not found at #{abs_binary_path}")
        {:error, "Corrosion binary not found at: #{abs_binary_path}"}

      not is_executable?(abs_binary_path) ->
        Logger.error("CorrosionCLI: Binary not executable at #{abs_binary_path}")
        {:error, "Corrosion binary is not executable: #{abs_binary_path}"}

      not File.exists?(abs_config_path) ->
        Logger.error("CorrosionCLI: Config not found at #{abs_config_path}")
        {:error, "Corrosion config not found at: #{abs_config_path}"}

      true ->
        # Logger.debug("CorrosionCLI: Prerequisites validated successfully")
        :ok
    end
  end

  # Helper function to check if a file is executable
  defp is_executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        # Check if owner execute bit is set (0o100)
        # Use Bitwise.band/2 for bitwise AND operation
        import Bitwise
        (mode &&& 0o100) != 0

      {:error, _} ->
        false
    end
  end

  defp execute_port_command(binary_path, args, _timeout) do
    # Convert to absolute path to help with path resolution
    abs_binary_path = Path.absname(binary_path)

    # Logger.debug("CorrosionCLI: Current working directory: #{File.cwd!()}")
    # Logger.debug("CorrosionCLI: Full command: #{abs_binary_path} #{Enum.join(args, " ")}")

    try do
      # Use System.cmd with basic options (no timeout for now)
      case System.cmd(abs_binary_path, args, stderr_to_stdout: true) do
        {output, 0} ->
          # Logger.debug("CorrosionCLI: Raw output: #{inspect(output)}")
          {:ok, output}

        {error_output, exit_code} ->
          Logger.warning("CorrosionCLI: Command failed with exit code #{exit_code}")
          Logger.warning("CorrosionCLI: Error output: #{error_output}")
          {:error, {:exit_code, exit_code, error_output}}
      end
    catch
      :exit, {:enoent, _} ->
        Logger.error("CorrosionCLI: Binary not found at #{abs_binary_path}")

        {:error,
         "Binary not found: #{abs_binary_path}. Check that the corrosion binary exists and is executable."}

      error ->
        Logger.error("CorrosionCLI: Unexpected error: #{inspect(error)}")
        {:error, {:unexpected_error, error}}
    end
  end

  @doc """
  Parses cluster members JSON output into a structured format.

  This is a helper function for processing the output of cluster_members/1.
  Returns a list of member maps with parsed state information.

  ## Parameters
  - `json_output` - Raw JSON string output from cluster_members command

  ## Returns
  - `{:ok, members}` - List of parsed member maps
  - `{:error, reason}` - Parse error details
  """
  def parse_cluster_members(json_output) when is_binary(json_output) do
    try do
      # The output appears to be multiple JSON objects, one per line
      # Let's split by lines and parse each JSON object
      lines = String.split(json_output, "\n", trim: true)

      members =
        Enum.map(lines, fn line ->
          case Jason.decode(line) do
            {:ok, member_data} ->
              # Add some parsed/computed fields for easier access
              member_data
              |> add_parsed_address()
              |> add_member_status()

            {:error, _} ->
              Logger.warning("CorrosionCLI: Failed to parse member line: #{line}")
              %{"parse_error" => line}
          end
        end)

      valid_members = Enum.reject(members, &Map.has_key?(&1, "parse_error"))

      Logger.info("CorrosionCLI: Parsed #{length(valid_members)} cluster members")
      {:ok, valid_members}
    rescue
      error ->
        Logger.error("CorrosionCLI: Error parsing cluster members: #{inspect(error)}")
        {:error, {:parse_error, error}}
    end
  end

  defp add_parsed_address(member) do
    case get_in(member, ["state", "addr"]) do
      addr when is_binary(addr) ->
        Map.put(member, "parsed_addr", addr)

      _ ->
        Map.put(member, "parsed_addr", "unknown")
    end
  end

  defp add_member_status(member) do
    # Add a computed status based on available data
    # This is a placeholder - we'll refine based on actual corrosion output
    status =
      cond do
        get_in(member, ["state", "last_sync_ts"]) != nil -> "active"
        get_in(member, ["state", "ts"]) != nil -> "connected"
        true -> "unknown"
      end

    Map.put(member, "computed_status", status)
  end
end
