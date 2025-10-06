import Config

# Get node ID from environment, default to 1
node_id = String.to_integer(System.get_env("NODE_ID") || "1")

# Calculate ports based on node ID
phoenix_port = 4000 + node_id
# New API port
ack_api_port = 5000 + node_id
corrosion_api_port = 8080 + node_id
corrosion_gossip_port = 8786 + node_id

# Runtime config path (used by Corrosion agent)
# Canonical configs are in corrosion/configs/canonical/
# Runtime configs (editable) are in corrosion/configs/runtime/
config_path = "corrosion/configs/runtime/node#{node_id}.toml"

# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :corro_port, CorroPortWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: phoenix_port],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "IwAz1v+95qyPXhnNQPyoIMfl6xqAo6an4o3/JMPOPhCV6BLxISJ0bNup6nIsooE7",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:corro_port, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:corro_port, ~w(--watch)]}
  ]

config :corro_port, CorroPortWeb.APIEndpoint,
  http: [ip: {127, 0, 0, 1}, port: ack_api_port],
  secret_key_base: "IwAz1v+95qyPXhnNQPyoIMfl6xqAo6an4o3/JMPOPhCV6BLxISJ0bNup6nIsooE7",
  server: true

# Store the node configuration for use by the application
# Note: Runtime configs are copied from canonical configs by startup scripts
# ConfigManager edits only runtime configs, leaving canonical configs unchanged
config :corro_port, :node_config,
  # Changed to include region prefix
  node_id: "dev-node#{node_id}",
  phoenix_port: phoenix_port,
  ack_api_port: ack_api_port,
  corrosion_api_port: corrosion_api_port,
  corrosion_gossip_port: corrosion_gossip_port,
  corro_config_path: config_path,
  corrosion_binary: "corrosion/corrosion-mac",
  environment: :dev,
  # Add this for development
  fly_region: "dev"

# Configure Analytics Repo with node-specific database
config :corro_port, CorroPort.Analytics.Repo, database: "analytics/analytics_node#{node_id}.db"

# Watch static and templates for browser reloading.
# Last regex is to exclude corrosion and analytics directories from live reload file watching
# to prevent recompilation when SQLite databases are modified (that wasn't what's triggering it though)

config :corro_port, CorroPortWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/corro_port_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$",
      ~r"lib/(?!corrosion|analytics)/.*\.(ex)$"
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

# Configure corro_cli for development
config :corro_cli,
  binary_path: "corrosion/corrosion-mac",
  config_path: config_path
