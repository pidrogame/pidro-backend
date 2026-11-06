defmodule PidroServerWeb.Dev.AnalyticsLiveTest do
  use PidroServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_admin

  test "connection outcomes show both shares and sample sizes for seven and thirty days", %{
    conn: conn
  } do
    for {turns, bots, finished, age} <- [{9, 3, false, 0}, {3, 3, true, 8}] do
      PidroServer.Stats.record_table_outcome(%{
        game_instance_id: Ecto.UUID.generate(),
        turns: turns,
        bot_turns: bots,
        others_finished: finished,
        cohorts: [%{platform: "android", app_version: "3.2.4"}],
        inserted_at:
          NaiveDateTime.utc_now()
          |> NaiveDateTime.add(-age, :day)
          |> NaiveDateTime.truncate(:second)
      })
    end

    PidroServer.DataCase.await_tasks()
    {:ok, view, _} = live(conn, "/admin/analytics")
    assert has_element?(view, "[data-connection-period='7']", "33.3%")
    assert has_element?(view, "[data-connection-period='7']", "0.0%")
    assert has_element?(view, "[data-connection-period='7']", "1 takeover games")
    assert has_element?(view, "[data-connection-period='30']", "50.0%")
    assert has_element?(view, "[data-connection-period='30']", "2 takeover games")
    assert has_element?(view, "#connection-analytics", "Bot-played turns")
    assert has_element?(view, "#connection-analytics", "All other humans finished")
  end

  test "uptime reflects the Erlang node, not the page's mount time", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/analytics")

    {node_uptime_ms, _} = :erlang.statistics(:wall_clock)
    node_uptime_s = div(node_uptime_ms, 1000)

    [_, h, m, s] = Regex.run(~r/(\d+)h (\d+)m (\d+)s/, html)
    shown = String.to_integer(h) * 3600 + String.to_integer(m) * 60 + String.to_integer(s)

    # The test VM has been running for a while by the time this renders. A
    # value measured from mount would be 0s here.
    assert shown > 0
    assert_in_delta shown, node_uptime_s, 2
  end
end
