defmodule PidroServerWeb.API.EntitlementsRefreshTest do
  # Not async: the rate-limit table and policies are shared by the node.
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures

  defp refresh(user) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
    |> post(~p"/api/v1/me/entitlements/refresh")
  end

  defp stub_subscriber(name) do
    body = File.read!(Path.expand("../../../fixtures/revenuecat/#{name}.json", __DIR__))
    Req.Test.stub(PidroServer.RevenueCat, &Req.Test.json(&1, Jason.decode!(body)))
  end

  test "syncs the player and answers the premium fields" do
    user = AccountsFixtures.user_fixture()
    stub_subscriber("active")

    assert json_response(refresh(user), 200) == %{
             "data" => %{
               "premium" => true,
               "premium_until" => "2099-11-07T10:00:00Z",
               "premium_source" => "store"
             }
           }

    stub_subscriber("expired")

    assert json_response(refresh(user), 200)["data"] ==
             %{"premium" => false, "premium_until" => nil, "premium_source" => nil}
  end

  test "needs a signed-in player" do
    assert build_conn() |> post(~p"/api/v1/me/entitlements/refresh") |> json_response(401)
  end

  test "RevenueCat failing answers 503 premium_unavailable" do
    user = AccountsFixtures.user_fixture()
    Req.Test.stub(PidroServer.RevenueCat, &Plug.Conn.send_resp(&1, 502, ""))

    {conn, _log} = ExUnit.CaptureLog.with_log(fn -> refresh(user) end)

    assert %{
             "error_code" => "premium_unavailable",
             "errors" => [%{"code" => "PREMIUM_UNAVAILABLE"}]
           } =
             json_response(conn, 503)
  end

  test "is limited per player" do
    user = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()
    stub_subscriber("no_entitlement")
    with_limit(:entitlements_refresh, 2, 60_000)

    assert refresh(user).status == 200
    assert refresh(user).status == 200

    limited = refresh(user)
    assert limited.status == 429
    assert [_seconds] = get_resp_header(limited, "retry-after")

    assert refresh(other).status == 200
  end
end
