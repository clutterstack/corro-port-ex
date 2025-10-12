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

  pipeline :api do
    plug :accepts, ["json"]
    plug CORSPlug, origin: "*"
  end

  scope "/", CorroPortWeb do
    pipe_through :browser

    live "/", PropagationLive
    live "/cluster", ClusterLive
    live "/node", NodeLive
    live "/messages", MessagesLive
    live "/analytics", AnalyticsLive
    live "/query-console", QueryConsoleLive
  end

  scope "/api", CorroPortWeb do
    pipe_through :api

    # Analytics data endpoints
    get "/analytics/health", AnalyticsApiController, :health

    get "/analytics/experiments/:experiment_id/summary",
        AnalyticsApiController,
        :experiment_summary

    get "/analytics/experiments/:experiment_id/timing", AnalyticsApiController, :timing_stats
    get "/analytics/experiments/:experiment_id/metrics", AnalyticsApiController, :system_metrics
    get "/analytics/experiments/:experiment_id/events", AnalyticsApiController, :message_events

    get "/analytics/experiments/:experiment_id/topology",
        AnalyticsApiController,
        :topology_snapshots

    # Analytics export endpoints
    get "/analytics/experiments/list", AnalyticsApiController, :list_experiments
    get "/analytics/experiments/compare", AnalyticsApiController, :export_comparison

    get "/analytics/experiments/:experiment_id/export",
        AnalyticsApiController,
        :export_experiment

    # Analytics control endpoints
    post "/analytics/aggregation/start", AnalyticsApiController, :start_aggregation
    post "/analytics/aggregation/stop", AnalyticsApiController, :stop_aggregation
    get "/analytics/aggregation/status", AnalyticsApiController, :aggregation_status

    # Message sending endpoint
    post "/messages/send", AnalyticsApiController, :send_message
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
