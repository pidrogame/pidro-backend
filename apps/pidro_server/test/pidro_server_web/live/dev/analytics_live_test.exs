defmodule PidroServerWeb.Dev.AnalyticsLiveTest do
  use PidroServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_admin

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
