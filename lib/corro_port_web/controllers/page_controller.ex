defmodule CorroPortWeb.PageController do
  use CorroPortWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
