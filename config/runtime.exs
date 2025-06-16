import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/corro_port start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :corro_port, CorroPortWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "8080")
  api_port = String.to_integer(System.get_env("API_PORT") || "8081")

  config :corro_port, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Main web endpoint
  config :corro_port, CorroPortWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  # API endpoint configuration
  fly_private_ip = System.get_env("FLY_PRIVATE_IP")
  fly_app_name = System.get_env("FLY_APP_NAME")
  fly_machine_id = System.get_env("FLY_MACHINE_ID")

  if fly_private_ip do
    # Parse IPv6 address for API endpoint
    case :inet.parse_address(String.to_charlist(fly_private_ip)) do
      {:ok, ipv6_tuple} ->
        config :corro_port, CorroPortWeb.APIEndpoint,
          http: [ip: ipv6_tuple, port: api_port],
          secret_key_base: secret_key_base,
          server: true

      {:error, _} ->
        Logger.warning(
          "Failed to parse FLY_PRIVATE_IP: #{fly_private_ip}, falling back to all interfaces"
        )

        config :corro_port, CorroPortWeb.APIEndpoint,
          http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: api_port],
          secret_key_base: secret_key_base,
          server: true
    end
  else
    # Fallback to all interfaces if no private IP
    config :corro_port, CorroPortWeb.APIEndpoint,
      http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: api_port],
      secret_key_base: secret_key_base,
      server: true
  end

  # Update node config with production settings
  if fly_app_name && fly_private_ip && fly_machine_id do
    config :corro_port, :node_config,
      node_id: fly_machine_id,
      api_port: api_port,
      corrosion_api_port: 8081,
      corrosion_gossip_port: 8787,
      corrosion_bootstrap_list: "[\"#{fly_app_name}.internal:8787\"]",
      corro_config_path: "/app/corrosion.toml",
      corrosion_binary: "/app/corrosion",
      environment: :prod,
      fly_app_name: fly_app_name,
      private_ip: fly_private_ip,
      fly_machine_id: fly_machine_id
  else
    # Fallback configuration
    config :corro_port, :node_config,
      node_id: System.get_env("NODE_ID", "fallback"),
      api_port: api_port,
      corrosion_api_port: 8081,
      corrosion_gossip_port: 8787,
      corrosion_bootstrap_list: "[]",
      corro_config_path: "/app/corrosion.toml",
      corrosion_binary: "/app/corrosion",
      environment: :prod
  end
end
