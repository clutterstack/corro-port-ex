import Config

# Get node ID from environment, default to 1
node_id = String.to_integer(System.get_env("NODE_ID") || "1")

# Calculate ports based on node ID
phoenix_port = 4000 + node_id
ack_port = 5000 + node_id  # Ack endpoint on separate port
corrosion_api_port = 8080 + node_id
corrosion_gossip_port = 8786 + node_id

# Main Phoenix endpoint (web UI)
config :corro_port, CorroPortWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: phoenix_port],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "IwAz1v+95qyPXhnNQPyoIMfl6xqAo6an4o3/JMPOPhCV6BLxISJ0bNup6nIsooE7",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:corro_port, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:corro_port, ~w(--watch)]}
  ]

# Acknowledgment endpoint (API only)
config :corro_port, CorroPortWeb.AckEndpoint,
  http: [ip: {127, 0, 0, 1}, port: ack_port],
  secret_key_base: "IwAz1v+95qyPXhnNQPyoIMfl6xqAo6an4o3/JMPOPhCV6BLxISJ0bNup6nIsooE7",
  server: true

# Store the node configuration for use by the Corrosion GenServer
config :corro_port, :node_config,
  node_id: node_id,
  corrosion_api_port: corrosion_api_port,
  corrosion_gossip_port: corrosion_gossip_port,
  ack_port: ack_port,
  originating_ip: "127.0.0.1"  # Development IP

# Watch static and templates for browser reloading.
config :corro_port, CorroPortWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/corro_port_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :corro_port, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include HEEx debug annotations as HTML comments in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
