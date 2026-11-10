defmodule PidroServerWeb.Dev.PremiumLiveTest do
  # Not async: one test swaps the RevenueCat config for the whole node.
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.{AccountsFixtures, Profiles, Repo}
  alias PidroServer.Entitlements.Entitlement

  test "anonymous requests are redirected to admin login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/premium")
  end

  describe "an admin" do
    setup :register_and_log_in_admin

    test "with nothing to show says so in words", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/premium")

      assert has_element?(view, "a[href='/admin/premium'][aria-current='page']", "Premium")
      assert view |> element("#premium-rows") |> render() =~ "Nobody is Premium yet."

      assert view |> element("#classic-waiting") |> render() =~
               "No Classic subscriber has claimed yet."

      refute has_element?(view, "table")
      refute has_element?(view, "#premium-unconfigured")
    end

    test "shows the numbers, the Premium rows and the Classic subscribers still waiting", %{
      conn: conn
    } do
      %{soon: soon, promo: promo, lapsed: lapsed, lifetime: lifetime, waiting: waiting} = seed()

      {:ok, view, _html} = live(conn, ~p"/admin/premium")

      summary = view |> element("#premium-summary") |> render()

      for {label, value} <- [
            {"Premium now", 3},
            {"Ending within 7 days", 1},
            {"Classic subscribers claimed", 2},
            {"Of those, not Premium here yet", 1}
          ] do
        assert summary =~ ~r/#{label}\s*<\/dt>\s*<dd[^>]*>#{value}<\/dd>/
      end

      assert view |> element("#premium-by-store") |> render() =~ "play_store"
      assert view |> element("#premium-by-source") |> render() =~ "promotional"

      for user <- [soon, promo, lifetime] do
        assert has_element?(view, "#premium-rows a[href='/admin/users/#{user.id}#premium']")
      end

      refute has_element?(view, "#premium-rows a[href='/admin/users/#{lapsed.id}#premium']")
      assert view |> element("#premium-rows") |> render() =~ "Never (lifetime)"

      waiting_html = view |> element("#classic-waiting") |> render()
      assert waiting_html =~ "PID-391"
      assert waiting_html =~ "old_subscriber"
      assert waiting_html =~ "Nov 01, 2026 09:00 UTC"
      assert has_element?(view, "#classic-waiting a[href='/admin/users/#{waiting.id}#premium']")
      refute has_element?(view, "#classic-waiting a[href='/admin/users/#{lifetime.id}#premium']")

      view |> form("#premium-filter", %{active_only: "false"}) |> render_change()

      assert has_element?(view, "#premium-rows a[href='/admin/users/#{lapsed.id}#premium']")
      assert view |> element("#premium-row-#{lapsed.id}") |> render() =~ "Ended"
    end

    test "without RevenueCat says nobody is Premium and still shows everything", %{conn: conn} do
      config = Application.fetch_env!(:pidro_server, PidroServer.RevenueCat)
      on_exit(fn -> Application.put_env(:pidro_server, PidroServer.RevenueCat, config) end)

      Application.put_env(:pidro_server, PidroServer.RevenueCat,
        secret_key: nil,
        webhook_secret: nil
      )

      %{soon: soon} = seed()
      {:ok, view, _html} = live(conn, ~p"/admin/premium")

      assert view |> element("#premium-unconfigured") |> render() =~
               "nobody is Premium until"

      assert has_element?(view, "#premium-rows a[href='/admin/users/#{soon.id}#premium']")
      assert has_element?(view, "#classic-waiting table")
    end
  end

  defp seed do
    soon = AccountsFixtures.user_fixture(%{username: "soon_store"})
    promo = AccountsFixtures.user_fixture(%{username: "promo_grant"})
    lapsed = AccountsFixtures.user_fixture(%{username: "lapsed_store"})
    lifetime = classic(AccountsFixtures.user_fixture(%{username: "lifetime_buyer"}), 5001)
    waiting = classic(AccountsFixtures.user_fixture(%{username: "still_waiting"}), 5002)

    for {user, attrs} <- [
          {soon, expires_at: from_now(3), store: "app_store"},
          {promo, expires_at: from_now(30), store: "promotional", source: "promotional"},
          {lapsed, expires_at: from_now(-1), store: "app_store"},
          {lifetime, expires_at: nil, store: "play_store"}
        ] do
      Repo.insert!(
        struct(
          %Entitlement{user_id: user.id, entitlement: "premium", active: true, source: "store"},
          attrs
        )
      )
    end

    %{soon: soon, promo: promo, lapsed: lapsed, lifetime: lifetime, waiting: waiting}
  end

  defp classic(user, classic_id) do
    user
    |> Ecto.Changeset.change(
      classic_user_id: classic_id,
      classic_claimed_at: ~U[2026-11-01 09:00:00.000000Z]
    )
    |> Repo.update!()

    username = if classic_id == 5002, do: "old_subscriber", else: "old_lifetime"

    {:ok, _profile} =
      Profiles.import_legacy_progression(user.id, %{premium: true, classic_username: username})

    user
  end

  defp from_now(days),
    do: DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
end
