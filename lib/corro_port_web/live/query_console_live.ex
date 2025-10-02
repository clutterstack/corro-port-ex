defmodule CorroPortWeb.QueryConsoleLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.ConnectionManager
  alias CorroPortWeb.NavTabs

  @max_history 5
  @default_preset "corro_members_all"

  @presets [
    %{
      id: "corro_members_all",
      label: "Corrosion Members",
      description: "Inspect the current \"__corro_members\" table exposed by the agent.",
      type: :sql,
      origin: "__corro_members table",
      exec: "SELECT * FROM __corro_members",
      params: []
    },
    %{
      id: "tracked_peers_all",
      label: "Tracked Peers",
      description: "Dump the CR-SQL tracked peers table for replication inspection.",
      type: :sql,
      origin: "crsql_tracked_peers table",
      exec: "SELECT * FROM crsql_tracked_peers",
      params: []
    },
    %{
      id: "node_messages_all",
      label: "Node Messages (All)",
      description: "Full ordered log of messages from all nodes.",
      type: :sql,
      origin: "MessagesAPI.get_node_messages/0",
      exec: "SELECT * FROM node_messages ORDER BY timestamp DESC",
      params: []
    },
    %{
      id: "node_messages_latest",
      label: "Node Messages (Latest per Node)",
      description: "Window query mirroring MessagesAPI.get_latest_node_messages/0.",
      type: :sql,
      origin: "messages_api.ex",
      exec: """
      SELECT message, node_id, timestamp, sequence, originating_endpoint, region
      FROM node_messages
      WHERE (node_id, timestamp) IN (
        SELECT node_id, MAX(timestamp)
        FROM node_messages
        GROUP BY node_id
      )
      ORDER BY timestamp DESC
      """,
      params: []
    },
    %{
      id: "active_regions",
      label: "Active Regions",
      description: "Distinct regions seen within the configured lookback window.",
      type: :sql,
      origin: "MessagesAPI.get_active_regions/1",
      exec: """
      SELECT DISTINCT region
      FROM node_messages
      WHERE timestamp > datetime('now', '-:minutes_ago minutes')
        AND region != 'unknown'
        AND region != ''
      ORDER BY region
      """,
      params: [
        %{
          name: "minutes_ago",
          label: "Minutes Ago",
          type: :integer,
          required: true,
          default: "60",
          min: 1,
          help: "Only include rows newer than this many minutes."
        }
      ]
    },
    %{
      id: "messages_by_region",
      label: "Messages by Region",
      description: "Filter node_messages by a specific region code.",
      type: :sql,
      origin: "MessagesAPI.get_messages_by_region/1",
      exec: "SELECT * FROM node_messages WHERE region = ':region' ORDER BY timestamp DESC",
      params: [
        %{
          name: "region",
          label: "Region",
          type: :string,
          required: true,
          placeholder: "iad",
          help: "Exact match against node_messages.region."
        }
      ]
    },
    %{
      id: "cluster_info",
      label: "Cluster Info",
      description: "Fetch Corrosion cluster metadata via CorroClient.",
      type: :api,
      origin: "CorroClient.get_cluster_info/1",
      exec: {:corro_client, :get_cluster_info, 1},
      params: []
    },
    %{
      id: "database_info",
      label: "Database Info",
      description: "Fetch Corrosion database metadata via CorroClient.",
      type: :api,
      origin: "CorroClient.get_database_info/1",
      exec: {:corro_client, :get_database_info, 1},
      params: []
    }
  ]

  @preset_lookup Map.new(@presets, &{&1.id, &1})

  @impl true
  def mount(_params, _session, socket) do
    presets = @presets
    selected = preset_by_id(@default_preset) || List.first(presets)

    socket =
      assign(socket, %{
        page_title: "Query Console",
        nav_active: :query_console,
        presets: presets,
        selected_preset_id: selected.id,
        params: default_params(selected),
        param_errors: %{},
        last_result: nil,
        run_history: [],
        loading?: false
      })

    {:ok, socket}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    preset = preset_by_id(id) || preset_by_id(socket.assigns.selected_preset_id)

    socket =
      assign(socket, %{
        selected_preset_id: preset.id,
        params: default_params(preset),
        param_errors: %{}
      })

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_param", %{"params" => new_params}, socket) do
    params = Map.merge(socket.assigns.params, new_params)
    cleared_errors = Map.drop(socket.assigns.param_errors, Map.keys(new_params))

    {:noreply, assign(socket, params: params, param_errors: cleared_errors)}
  end

  @impl true
  def handle_event("run", %{"params" => submitted_params} = _event, socket) do
    params = Map.merge(socket.assigns.params, submitted_params)
    socket = assign(socket, :params, params)
    preset = current_preset(socket)

    case validate_params(preset, params) do
      :ok ->
        do_run(preset, params, socket)

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:param_errors, errors)
         |> put_flash(:error, error_message_for(errors))}
    end
  end

  @impl true
  def handle_event("run", _event, socket) do
    preset = current_preset(socket)
    params = socket.assigns.params

    case validate_params(preset, params) do
      :ok ->
        do_run(preset, params, socket)

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:param_errors, errors)
         |> put_flash(:error, error_message_for(errors))}
    end
  end

  @impl true
  def handle_event("sql_copied", %{"label" => label}, socket) do
    {:noreply, put_flash(socket, :info, "Copied SQL for #{label} preset")}
  end

  @impl true
  def handle_event("sql_copy_failed", %{"label" => label}, socket) do
    {:noreply, put_flash(socket, :error, "Unable to copy SQL for #{label} preset")}
  end

  defp do_run(preset, params, socket) do
    conn = resolve_connection()
    socket = assign(socket, :loading?, true)

    case execute_preset(preset, params, conn) do
      {:ok, payload, duration_ms} ->
        result = %{
          preset_id: preset.id,
          status: :ok,
          payload: payload,
          ran_at: DateTime.utc_now(),
          duration_ms: duration_ms
        }

        history = build_history(result, preset, socket.assigns.run_history)

        {:noreply,
         socket
         |> assign(:loading?, false)
         |> assign(:last_result, Map.put(result, :label, preset.label))
         |> assign(:run_history, history)
         |> assign(:param_errors, %{})}

      {:error, reason, duration_ms} ->
        result = %{
          preset_id: preset.id,
          status: :error,
          payload: reason,
          ran_at: DateTime.utc_now(),
          duration_ms: duration_ms
        }

        history = build_history(result, preset, socket.assigns.run_history)

        {:noreply,
         socket
         |> assign(:loading?, false)
         |> assign(:last_result, Map.put(result, :label, preset.label))
         |> assign(:run_history, history)
         |> put_flash(:error, "Query run failed: #{inspect(reason)}")}
    end
  end

  defp execute_preset(%{type: :sql, exec: sql} = preset, params, conn) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        rendered_sql = render_sql(preset, params, sql)
        client_module().query(conn, rendered_sql)
      rescue
        error -> {:error, error}
      end

    finalize_execution(result, preset, started)
  end

  defp execute_preset(%{type: :api, exec: {:corro_client, fun, arity}} = preset, _params, conn) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        args = Enum.take([conn], arity)
        apply(client_module(), fun, args)
      rescue
        error -> {:error, error}
      end

    finalize_execution(result, preset, started)
  end

  defp finalize_execution(result, preset, started) do
    duration_ms = System.monotonic_time(:millisecond) - started

    case normalize_result(result) do
      {:ok, payload} ->
        Logger.info("query_console_run",
          preset_id: preset.id,
          type: preset.type,
          status: :ok,
          duration_ms: duration_ms
        )

        {:ok, payload, duration_ms}

      {:error, reason} ->
        Logger.info("query_console_run",
          preset_id: preset.id,
          type: preset.type,
          status: :error,
          duration_ms: duration_ms,
          reason: inspect(reason)
        )

        {:error, reason, duration_ms}
    end
  end

  defp normalize_result({:ok, payload}), do: {:ok, payload}
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(other), do: {:ok, other}

  defp render_sql(preset, params, sql) do
    Enum.reduce(preset.params, sql, fn meta, acc ->
      placeholder = ":" <> meta.name
      value = Map.get(params, meta.name, "")
      sanitized = sanitize_for_sql(value, meta)
      String.replace(acc, placeholder, sanitized)
    end)
  end

  defp sanitize_for_sql(value, %{type: :integer} = meta) do
    sanitized =
      value
      |> to_string()
      |> String.trim()
      |> String.replace(~r/[^0-9]/, "")

    case sanitized do
      "" ->
        maybe_default_integer(meta)

      digits ->
        int = String.to_integer(digits)
        min = Map.get(meta, :min)

        if min && int < min do
          Integer.to_string(min)
        else
          Integer.to_string(int)
        end
    end
  end

  defp sanitize_for_sql(value, _meta) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace("'", "''")
  end

  defp maybe_default_integer(meta) do
    default = Map.get(meta, :default, "0") |> to_string()

    case Integer.parse(default) do
      {int, _} -> Integer.to_string(int)
      :error -> "0"
    end
  end

  defp validate_params(preset, params) do
    errors =
      preset.params
      |> Enum.reduce(%{}, fn meta, acc ->
        value = Map.get(params, meta.name, "")

        case validate_param(meta, value) do
          :ok -> acc
          {:error, message} -> Map.put(acc, meta.name, message)
        end
      end)

    if map_size(errors) == 0 do
      :ok
    else
      {:error, errors}
    end
  end

  defp validate_param(%{required: true} = meta, value) do
    value = value |> to_string() |> String.trim()

    cond do
      value == "" ->
        {:error, "#{meta.label || meta.name} is required"}

      meta[:type] == :integer and not valid_integer?(value, meta) ->
        {:error, "Enter a valid integer"}

      true ->
        :ok
    end
  end

  defp validate_param(%{type: :integer} = meta, value) do
    if value == "" do
      :ok
    else
      if valid_integer?(value, meta), do: :ok, else: {:error, "Enter a valid integer"}
    end
  end

  defp validate_param(_meta, _value), do: :ok

  defp valid_integer?(value, meta) do
    with {int, ""} <- Integer.parse(value),
         min <- Map.get(meta, :min),
         true <- is_nil(min) or int >= min do
      true
    else
      _ -> false
    end
  end

  defp error_message_for(errors) do
    errors
    |> Map.values()
    |> Enum.uniq()
    |> Enum.join(". ")
  end

  defp resolve_connection do
    Application.get_env(:corro_port, :query_console_connection) ||
      ConnectionManager.get_connection()
  end

  defp client_module do
    Application.get_env(:corro_port, :query_console_client, CorroClient)
  end

  defp build_history(result, preset, history) do
    entry = %{
      preset_id: preset.id,
      label: preset.label,
      status: result.status,
      duration_ms: result.duration_ms,
      ran_at: result.ran_at
    }

    [entry | history] |> Enum.take(@max_history)
  end

  defp current_preset(socket) do
    preset_by_id(socket.assigns.selected_preset_id)
  end

  defp preset_by_id(id), do: Map.get(@preset_lookup, id)

  defp default_params(preset) do
    preset.params
    |> Enum.map(fn meta -> {meta.name, Map.get(meta, :default, "")} end)
    |> Enum.into(%{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 px-4 py-6 sm:px-6">
      <NavTabs.nav_tabs active={:query_console} />

      <% active_preset = preset_by_id(@selected_preset_id) %>

      <div class="grid gap-6 lg:grid-cols-5">
        <div class="lg:col-span-2 space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-400">Presets</h2>

          <div class="space-y-2">
            <%= for preset <- @presets do %>
              <button
                type="button"
                phx-click="select"
                phx-value-id={preset.id}
                class={[
                  "w-full rounded-lg border px-4 py-3 text-left transition",
                  preset.id == @selected_preset_id && "border-primary bg-primary/10 text-primary",
                  preset.id != @selected_preset_id && "border-base-300 hover:border-primary"
                ]}
              >
                <div class="flex items-center justify-between">
                  <p class="text-base font-semibold">{preset.label}</p>
                  <span class="badge badge-outline text-xs uppercase">{preset.type}</span>
                </div>
                <p class="mt-1 text-sm text-zinc-500">{preset.description}</p>
                <p class="mt-2 text-xs text-zinc-400">Origin: {preset.origin}</p>
              </button>
            <% end %>
          </div>
        </div>

        <div class="lg:col-span-3 space-y-6">
          <form
            class="rounded-xl border border-base-300 bg-base-200 p-6 shadow-sm"
            phx-submit="run"
            phx-change="update_param"
          >
            <div class="flex items-start justify-between">
              <div>
                <h2 class="text-lg font-semibold">{active_preset.label}</h2>
                <p class="text-sm text-zinc-500">{active_preset.description}</p>
              </div>

              <%= if active_preset.type == :sql do %>
                <button
                  type="button"
                  id={"copy-sql-#{active_preset.id}"}
                  class="btn btn-sm"
                  phx-hook="CopySQL"
                  data-clipboard={render_sql_for_display(active_preset, @params)}
                  data-sql-label={active_preset.label}
                >
                  Copy SQL
                </button>
              <% end %>
            </div>

            <div :if={active_preset.params != []} class="mt-4 space-y-4">
              <%= for meta <- active_preset.params do %>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">{meta.label || meta.name}</span>
                  </label>
                  <input
                    type="text"
                    name={"params[#{meta.name}]"}
                    value={Map.get(@params, meta.name, "")}
                    placeholder={meta[:placeholder] || ""}
                    class={[
                      "input input-bordered w-full",
                      Map.has_key?(@param_errors, meta.name) && "input-error"
                    ]}
                    phx-debounce="300"
                  />
                  <label :if={Map.has_key?(@param_errors, meta.name)} class="label">
                    <span class="label-text-alt text-error">{Map.get(@param_errors, meta.name)}</span>
                  </label>
                  <p :if={meta[:help]} class="mt-1 text-xs text-zinc-500">{meta[:help]}</p>
                </div>
              <% end %>
            </div>

            <div class="mt-6 flex items-center gap-2">
              <button
                type="submit"
                class="btn btn-primary"
                disabled={@loading? || !params_valid?(active_preset, @params)}
              >
                <%= if @loading? do %>
                  <span class="loading loading-spinner loading-xs mr-2" />
                <% end %>
                Run
              </button>
            </div>
          </form>

          <div class="rounded-xl border border-base-300 bg-base-100 p-6 shadow-sm">
            <h3 class="text-base font-semibold">Last Result</h3>
            <div :if={@last_result} class="mt-3 space-y-2">
              <div class="flex items-center gap-2 text-sm">
                <span class={[
                  "badge",
                  @last_result.status == :ok && "badge-success",
                  @last_result.status == :error && "badge-error"
                ]}>
                  {@last_result.status}
                </span>
                <span class="text-zinc-500">
                  Ran at {format_timestamp(@last_result.ran_at)} in {@last_result.duration_ms} ms
                </span>
              </div>
              <pre class="max-h-96 overflow-auto rounded-lg bg-base-200 p-4 text-sm">
    {inspect(@last_result.payload, pretty: true, limit: :infinity)}
              </pre>
            </div>
            <p :if={!@last_result} class="mt-2 text-sm text-zinc-500">
              No runs yet. Select a preset and execute it to inspect results.
            </p>
          </div>

          <div class="rounded-xl border border-base-300 bg-base-100 p-6 shadow-sm">
            <h3 class="text-base font-semibold">Recent Runs</h3>
            <ul class="mt-3 space-y-2 text-sm">
              <%= for entry <- @run_history do %>
                <li class="flex items-center justify-between rounded-lg bg-base-200 px-3 py-2">
                  <div>
                    <p class="font-medium">{entry.label}</p>
                    <p class="text-xs text-zinc-500">
                      {format_timestamp(entry.ran_at)} • {entry.duration_ms} ms
                    </p>
                  </div>
                  <span class={[
                    "badge badge-sm",
                    entry.status == :ok && "badge-success",
                    entry.status == :error && "badge-error"
                  ]}>
                    {entry.status}
                  </span>
                </li>
              <% end %>
              <li :if={@run_history == []} class="text-sm text-zinc-500">
                Run history is empty.
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp params_valid?(preset, params) do
    validate_params(preset, params) == :ok
  end

  defp render_sql_for_display(preset, params) do
    case preset do
      %{type: :sql, exec: sql} -> render_sql(preset, params, sql)
      _ -> ""
    end
  end

  defp format_timestamp(nil), do: ""

  defp format_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  rescue
    _ -> ""
  end
end
