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
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "8080")

  config :corro_port, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :corro_port, CorroPortWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Production Corrosion Configuration for fly.io
  fly_app_name = System.get_env("FLY_APP_NAME")
  fly_private_ip = System.get_env("FLY_PRIVATE_IP")
  fly_machine_id = System.get_env("FLY_MACHINE_ID")

  if fly_app_name && fly_private_ip && fly_machine_id do
    # Production fly.io configuration
    config :corro_port, :node_config,
      # Use FLY_MACHINE_ID for readable node identification
      node_id: fly_machine_id,
      # All nodes use the same API port on fly.io
      corrosion_api_port: 8081,
      # Each node gets its own private IP for gossip
      corrosion_gossip_port: 8787,
      # Use fly.io DNS for bootstrap discovery
      corrosion_bootstrap_list: "[\"#{fly_app_name}.internal:8787\"]",
      # Production config path
      corro_config_path: "/app/corrosion.toml",
      # Production binary path
      corrosion_binary: "/app/corrosion",
      # Production environment flag
      environment: :prod,
      # Fly.io specific settings
      fly_app_name: fly_app_name,
      fly_private_ip: fly_private_ip,
      fly_machine_id: fly_machine_id
  else
    # Fallback configuration if fly.io env vars are missing
    config :corro_port, :node_config,
      node_id: System.get_env("NODE_ID", "fallback"),
      corrosion_api_port: 8081,
      corrosion_gossip_port: 8787,
      corrosion_bootstrap_list: "[]",
      corro_config_path: "/app/corrosion.toml",
      corrosion_binary: "/app/corrosion",
      environment: :prod
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :corro_port, CorroPortWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :corro_port, CorroPortWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
