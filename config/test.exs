import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :corro_port, CorroPortWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qpWx9E+kYQUgluOTSEDRgEwK0y1QPfcuGl5If7+pNEMJmPqBrshShGruoPxtW2uz",
  server: false

config :corro_port, CorroPortWeb.APIEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 5002],
  secret_key_base: "qpWx9E+kYQUgluOTSEDRgEwK0y1QPfcuGl5If7+pNEMJmPqBrshShGruoPxtW2uz",
  server: false

# Test Analytics Repo with in-memory database
config :corro_port, CorroPort.Analytics.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: ":memory:",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Test node configuration
config :corro_port, :node_config,
  node_id: "test-node1",
  phoenix_port: 4002,
  ack_api_port: 5002,
  corrosion_api_port: 8082,
  corrosion_gossip_port: 8788,
  corro_config_path: "test/fixtures/config-test.toml",
  corrosion_binary: "test/fixtures/corrosion-mock",
  environment: :test,
  fly_region: "test"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
