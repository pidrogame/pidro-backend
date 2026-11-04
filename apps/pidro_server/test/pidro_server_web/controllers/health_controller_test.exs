defmodule PidroServerWeb.HealthControllerTest do
  use PidroServerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  test "GET /up", %{conn: conn} do
    conn = get(conn, ~p"/up")

    assert response(conn, 200) == "ok"
  end

  test "a request that went well is not logged at info; a refused one is", %{conn: conn} do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    ok = capture_log([level: :info], fn -> get(conn, ~p"/up") end)
    refute ok =~ "GET /up"
    refute ok =~ "Sent 200"

    refused = capture_log([level: :info], fn -> get(conn, ~p"/api/v1/auth/me") end)
    assert refused =~ "Sent 401"
  end
end
