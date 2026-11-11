defmodule PidroServerWeb.Dev.UserPremiumLiveTest do
  # Not async: the LiveView process reaches the shared RevenueCat stub, and one
  # test swaps the RevenueCat config for the whole node.
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.AccountsFixtures
  alias PidroServer.Entitlements
  alias PidroServer.Entitlements.{Entitlement, RevenueCatEvent}
  alias PidroServer.Repo

  setup :register_and_log_in_admin

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
  end

  defp fixture(name),
    do:
      File.read!(Path.expand("../../../fixtures/revenuecat/#{name}.json", __DIR__))
      |> Jason.decode!()

  test "shows the Classic Premium carry-over, when there is one", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()

    Repo.insert!(%PidroServer.ClassicPremium.Carryover{
      user_id: user.id,
      classic_user_id: 7001,
      state: "pending",
      attempts: 3,
      classic_premium_until: ~U[2027-02-01 00:00:00Z],
      last_error: "{:revenuecat_status, 500}",
      last_tried_at: ~U[2026-11-11 08:00:00Z]
    })

    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")
    carryover = view |> element("#premium #classic-premium") |> render()

    assert carryover =~ "pending"
    assert carryover =~ "3 failed"
    assert carryover =~ "Feb 01, 2027 00:00 UTC"
    assert carryover =~ "Nov 11, 2026 08:00 UTC"
    assert carryover =~ "{:revenuecat_status, 500}"

    {:ok, view, _html} = live(conn, ~p"/admin/users/#{other.id}")
    refute has_element?(view, "#classic-premium")
  end

  test "shows the entitlement row and the last raw event", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    Repo.insert!(%Entitlement{
      user_id: user.id,
      entitlement: "premium",
      active: true,
      expires_at: ~U[2027-11-07 10:00:00Z],
      product_id: "pidro.yearauto",
      store: "app_store",
      source: "store",
      last_synced_at: ~U[2026-11-07 10:00:05Z]
    })

    Repo.insert!(%RevenueCatEvent{
      event_id: "evt-1",
      type: "INITIAL_PURCHASE",
      app_user_id: user.id,
      payload: %{"id" => "evt-1", "type" => "INITIAL_PURCHASE", "app_user_id" => user.id},
      processed_at: ~U[2026-11-07 10:00:05Z]
    })

    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")
    premium = view |> element("#premium") |> render()

    assert premium =~ "Premium"
    assert premium =~ "Active"
    assert premium =~ "Nov 07, 2027 10:00 UTC"
    assert premium =~ "pidro.yearauto"
    assert premium =~ "app_store"
    assert premium =~ "store"
    assert premium =~ "Nov 07, 2026 10:00 UTC"
    assert premium =~ "INITIAL_PURCHASE"
    assert view |> element("#premium details") |> render() =~ "&quot;evt-1&quot;"
  end

  test "a player without Premium says so", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")

    assert view |> element("#premium") |> render() =~ "Not Premium. No entitlement row yet."
    assert view |> element("#premium") |> render() =~ "No RevenueCat event for this player yet."
  end

  test "grants Premium through RevenueCat and shows the synced row", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    test = self()

    Req.Test.stub(PidroServer.RevenueCat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:revenuecat, conn.method, body})
      Req.Test.json(conn, fixture("promotional"))
    end)

    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")

    html =
      view
      |> form("#premium-grant", premium: %{until: "2099-06-29"})
      |> render_submit()

    assert_received {:revenuecat, "POST", body}
    assert Jason.decode!(body) == %{"end_time_ms" => 4_086_460_799_000}
    assert_received {:revenuecat, "GET", _body}

    assert html =~ "Premium granted until Jun 30, 2099 00:00 UTC."
    assert view |> element("#premium") |> render() =~ "promotional"
    assert %Entitlement{source: "promotional", active: true} = Entitlements.get(user.id)
  end

  test "a date that is not in the future is refused before RevenueCat", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    Req.Test.stub(PidroServer.RevenueCat, fn _conn -> flunk("RevenueCat was called") end)

    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")

    html =
      view
      |> form("#premium-grant", premium: %{until: "2020-01-01"})
      |> render_submit()

    assert html =~ "Pick a date in the future."
    assert Entitlements.get(user.id) == nil
  end

  test "RevenueCat refusing the grant says so and writes nothing", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    Req.Test.stub(PidroServer.RevenueCat, &Plug.Conn.send_resp(&1, 400, "{}"))

    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")

    {html, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        view |> form("#premium-grant", premium: %{until: "2099-06-29"}) |> render_submit()
      end)

    assert html =~ "RevenueCat did not grant Premium"
    assert Entitlements.get(user.id) == nil
  end

  test "without RevenueCat the grant is disabled and says why", %{conn: conn} do
    config = Application.fetch_env!(:pidro_server, PidroServer.RevenueCat)
    on_exit(fn -> Application.put_env(:pidro_server, PidroServer.RevenueCat, config) end)

    Application.put_env(:pidro_server, PidroServer.RevenueCat,
      secret_key: nil,
      webhook_secret: nil
    )

    user = AccountsFixtures.user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")

    assert has_element?(view, "#premium-grant button[disabled]")
    assert has_element?(view, "#premium-grant input[disabled]")

    assert view |> element("#premium") |> render() =~
             "Add REVENUECAT_SECRET_KEY and REVENUECAT_WEBHOOK_SECRET to grant Premium."
  end
end
