defmodule PidroServerWeb.Dev.AdsLiveTest do
  use PidroServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PidroServer.{AccountsFixtures, Repo, Settings}
  alias PidroServer.Ads.Event

  test "anonymous requests are redirected to admin login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/ads")
  end

  describe "an admin" do
    setup :register_and_log_in_admin

    test "is linked from the admin nav and told the kill switch is off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ads")
      assert has_element?(view, "a[href='/admin/ads'][aria-current='page']", "Ads")
      assert view |> element("#ads-switch") |> render() =~ "Ads are off."
      assert view |> element("#ads-switch") |> render() =~ "Nobody is eligible"
    end

    test "saves the schedule, which a reload shows and ads/0 reads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ads")

      view
      |> form("#ads-form",
        ads: %{
          ads_enabled: "true",
          ads_free_games: "12",
          ads_early_every_n: "4",
          ads_games_until_steady: "30",
          ads_steady_every_n: "1"
        }
      )
      |> render_submit()

      assert Settings.ads() == %{
               ads_enabled: true,
               ads_free_games: 12,
               ads_early_every_n: 4,
               ads_games_until_steady: 30,
               ads_steady_every_n: 1
             }

      {:ok, view, _html} = live(conn, ~p"/admin/ads")
      assert has_element?(view, "#ads_ads_free_games[value='12']")
      assert has_element?(view, "#ads_ads_early_every_n[value='4']")
      assert has_element?(view, "#ads_ads_enabled[checked]")
      switch = view |> element("#ads-switch") |> render() |> String.replace(~r/\s+/, " ")
      assert switch =~ "before every 4th solo game; from 30 solo games, before every solo game."
    end

    test "an invalid value saves nothing and says why", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ads")

      html =
        view
        |> form("#ads-form", ads: %{ads_enabled: "true", ads_early_every_n: "0"})
        |> render_submit()

      assert html =~ "must be greater than or equal to 1"
      assert Settings.ads().ads_enabled == false
    end

    test "shows the last 14 days of events and the free adults past the free games",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture() |> Ecto.Changeset.change(age_band: "18_plus")
      user = Repo.update!(user)
      {:ok, profile} = PidroServer.Profiles.get_or_create_profile(user.id)
      profile |> Ecto.Changeset.change(games_played: 10) |> Repo.update!()

      for kind <- ~w(offered offered watched dismissed) do
        Repo.insert!(%Event{user_id: user.id, kind: kind})
      end

      {:ok, view, _html} = live(conn, ~p"/admin/ads")
      today = view |> element("#ads-day-#{Date.utc_today()}") |> render()
      assert today =~ Calendar.strftime(Date.utc_today(), "%-d %b")
      assert cells(today) == ["2", "1", "0", "1"]
      assert view |> element("#ads-past-free-games") |> render() =~ ~r/>\s*1\s*</
      assert view |> element("#ads-days") |> render() |> String.split("<tr") |> length() == 16
    end
  end

  defp cells(row_html) do
    ~r/<td class="[^"]*font-mono[^"]*">\s*(\d+)\s*<\/td>/
    |> Regex.scan(row_html, capture: :all_but_first)
    |> List.flatten()
  end
end
