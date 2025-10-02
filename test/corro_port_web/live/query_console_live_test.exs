defmodule CorroPortWeb.QueryConsoleLiveTest do
  use CorroPortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  require Logger

  defmodule FakeCorroClient do
    def query(:fake_conn, sql) do
      notify({:query, sql})
      {:ok, [%{"ok" => true, "sql" => sql}]}
    end

    def get_cluster_info(:fake_conn) do
      notify({:api_call, :get_cluster_info})
      {:ok, %{cluster: "ok"}}
    end

    def get_database_info(:fake_conn) do
      notify({:api_call, :get_database_info})
      {:ok, %{database: "ok"}}
    end

    defp notify(message) do
      if pid = Application.get_env(:corro_port, :query_console_test_pid) do
        send(pid, message)
      end
    end
  end

  setup %{conn: conn} do
    previous_client = Application.get_env(:corro_port, :query_console_client)
    previous_conn = Application.get_env(:corro_port, :query_console_connection)
    previous_pid = Application.get_env(:corro_port, :query_console_test_pid)

    Application.put_env(:corro_port, :query_console_client, FakeCorroClient)
    Application.put_env(:corro_port, :query_console_connection, :fake_conn)
    Application.put_env(:corro_port, :query_console_test_pid, self())

    on_exit(fn ->
      Application.put_env(:corro_port, :query_console_client, previous_client)
      Application.put_env(:corro_port, :query_console_connection, previous_conn)
      Application.put_env(:corro_port, :query_console_test_pid, previous_pid)
    end)

    {:ok, conn: conn}
  end

  test "renders preset list and selects default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/query-console")

    assert html =~ "Query Console"
    assert html =~ "Corrosion Members"
    assert html =~ "Query Console"
    assert html =~ "badge"
  end

  test "runs SQL preset and records history", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/query-console")

    previous_level = Logger.level()
    Logger.configure(level: :info)

    log =
      capture_log(fn ->
        view
        |> element("form")
        |> render_submit(%{"params" => %{}})

        assert_receive {:query, sql}
        assert sql =~ "__corro_members"
      end)

    Logger.configure(level: previous_level)

    assert log =~ "query_console_run"

    rendered = render(view)
    assert rendered =~ "badge-success"
    assert rendered =~ "__corro_members"
    assert rendered =~ "Recent Runs"
  end

  test "requires region parameter before running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/query-console")

    view
    |> element("button[phx-value-id=messages_by_region]")
    |> render_click()

    view
    |> element("form")
    |> render_submit(%{"params" => %{}})

    refute_received {:query, _}

    rendered = render(view)
    assert rendered =~ "Region is required"
  end

  test "runs API preset through client module", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/query-console")

    view
    |> element("button[phx-value-id=cluster_info]")
    |> render_click()

    view
    |> element("form")
    |> render_submit(%{"params" => %{}})

    assert_receive {:api_call, :get_cluster_info}
    assert render(view) =~ "cluster: &quot;ok&quot;"
  end
end
