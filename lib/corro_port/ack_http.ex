defmodule CorroPort.AckHttp do
  @moduledoc """
  Shared helpers for building acknowledgment HTTP requests.

  Centralising endpoint parsing and Req configuration keeps the Corrosion-driven
  acknowledgments and the PubSub test flow aligned on timeout and connection
  behaviour.
  """

  require Logger

  @default_receive_timeout 5_000
  @default_connect_timeout 2_000
  @default_headers [{"content-type", "application/json"}]

  @doc """
  Parse an originating endpoint string into a base URL (`http://host:port`).
  """
  @spec parse_endpoint(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_endpoint(endpoint) when is_binary(endpoint) do
    case endpoint do
      "[" <> rest ->
        parse_ipv6_endpoint(rest, endpoint)

      _ ->
        parse_ipv4_or_hostname(endpoint)
    end
  end

  def parse_endpoint(endpoint) do
    {:error, "Endpoint must be a string, got: #{inspect(endpoint)}"}
  end

  @doc """
  Build a URL by combining the base URL returned from `parse_endpoint/1` with a path.
  """
  @spec build_url(String.t(), String.t()) :: String.t()
  def build_url(base_url, path) do
    trimmed_base = String.trim_trailing(base_url, "/")
    trimmed_path = "/" <> String.trim_leading(path, "/")
    trimmed_base <> trimmed_path
  end

  @doc """
  Issue an HTTP POST for an acknowledgment payload using Req.

  Returns the result from `Req.post/2`. Exceptions raised by Req are caught and
  returned as `{:error, exception}` after being logged.
  """
  @spec post_ack(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post_ack(base_url, path, payload, opts \\ []) do
    url = build_url(base_url, path)

    req_opts = [
      url: url,
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      connect_options: [timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout)],
      headers: Keyword.get(opts, :headers, @default_headers)
    ]

    req = Req.new(req_opts)

    try do
      Req.post(req, json: payload)
    rescue
      exception ->
        Logger.warning(
          "AckHttp: Exception while posting acknowledgment to #{url}: #{Exception.message(exception)}"
        )

        {:error, exception}
    end
  end

  defp parse_ipv6_endpoint(rest, original) do
    case String.split(rest, "]:") do
      [ipv6, port_str] ->
        case Integer.parse(port_str) do
          {_port, ""} -> {:ok, "http://[#{ipv6}]:#{port_str}"}
          _ -> {:error, "Invalid port in IPv6 endpoint: #{original}"}
        end

      _ ->
        {:error, "Invalid IPv6 endpoint format: #{original}"}
    end
  end

  defp parse_ipv4_or_hostname(endpoint) do
    case String.split(endpoint, ":") do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {_port, ""} -> {:ok, "http://#{host}:#{port_str}"}
          _ -> {:error, "Invalid port in endpoint: #{endpoint}"}
        end

      _ ->
        {:error, "Invalid endpoint format: #{endpoint}"}
    end
  end
end