# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :corro_port,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoints
config :corro_port, CorroPortWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CorroPortWeb.ErrorHTML, json: CorroPortWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CorroPort.PubSub,
  live_view: [signing_salt: "MBbqxJvI"]

config :corro_port, CorroPortWeb.APIEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CorroPortWeb.ErrorHTML, json: CorroPortWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CorroPort.PubSub

# For FlyMapEx
config :fly_map_ex,
  custom_regions: %{
    # Whitehorse
    "dev-node1" => %{name: "dev-node1", coordinates: {60.7212, -135.0568}},
    # Yellowknife
    "dev-node2" => %{name: "dev-node2", coordinates: {62.454, -114.3718}},
    # Iqaluit
    "dev-node3" => %{name: "dev-node3", coordinates: {63.7467, -68.5207}}
  },
  default_presets: %{
    local: %{colour: "#e046ffff", size: 4},
    dns: %{colour: "#969494ff", size: 6},
    api: %{colour: "#8f45ffff", size: 6},
    cli: %{colour: "#4ec2f8ff", size: 4},
    acked: %{colour: "#54f25aff", size: 4}
  }

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  corro_port: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.0.9",
  corro_port: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Analytics Repo
config :corro_port, CorroPort.Analytics.Repo,
  adapter: Ecto.Adapters.SQLite3,
  pool_size: 5,
  priv: "priv/analytics_repo"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
