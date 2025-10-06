defmodule CorroPortWeb.APIRouter do
  use CorroPortWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", CorroPortWeb do
    pipe_through(:api)

    post("/acknowledge", AcknowledgmentController, :acknowledge)
    post("/acknowledge_pubsub", AcknowledgmentController, :acknowledge_pubsub)
    get("/acknowledge/health", AcknowledgmentController, :health)
  end
end