defmodule CorroPortWeb.APIEndpoint do
  @moduledoc """
  Separate Phoenix endpoint for private API communication between nodes.

  In production: Listens on fly.io 6PN private IPv6 address
  In development: Listens on localhost with different port per node
  """

  use Phoenix.Endpoint, otp_app: :corro_port

  # API-specific session options (minimal since this is for machine-to-machine)
  @session_options [
    store: :cookie,
    key: "_corro_api_key",
    signing_salt: "8NweqAPI",
    same_site: "Lax"
  ]

  # No LiveView needed for API endpoint
  # No static file serving needed for API endpoint

  # Basic plugs for API
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:corro_api, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # Use the same router but with API scope
  plug CorroPortWeb.APIRouter
end
