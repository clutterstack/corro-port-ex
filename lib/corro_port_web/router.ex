defmodule CorroPortWeb.Router do
  use CorroPortWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CorroPortWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", CorroPortWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/cluster", ClusterLive
    live "/node", NodeLive
    live "/messages", MessagesLive
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:corro_port, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CorroPortWeb.Telemetry
    end
  end
end
