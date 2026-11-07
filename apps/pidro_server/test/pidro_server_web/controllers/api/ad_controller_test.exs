defmodule PidroServerWeb.API.AdControllerTest do
  @moduledoc """
  The ad schedule over HTTP (PID-123): `/auth/me` carries the decision, an
  ad-aware solo room is held to it, an old client never is, and the app's
  reports give the credit and are counted.
  """

  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  alias PidroServer.Accounts.Token
  alias PidroServer.{AccountsFixtures, Profiles, Repo, Settings}
  alias PidroServer.Ads.Event
  alias PidroServer.Games.RoomManager

  import Ecto.Query

  @solo %{"seats" => %{"seat_2" => "ai", "seat_3" => "ai", "seat_4" => "ai"}}

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    Settings.put(:ads_enabled, true)
    :ok
  end

  # An adult past the free games whose next solo start is the 3rd.
  defp due_adult(age_band \\ "18_plus") do
    user =
      AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(age_band: age_band)
      |> Repo.update!()

    {:ok, profile} = Profiles.get_or_create_profile(user.id)

    profile
    |> Ecto.Changeset.change(games_played: 10, solo_games_started: 2)
    |> Repo.update!()

    user
  end

  defp as_user(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")

  defp create_room(user, body), do: build_conn() |> as_user(user) |> post(~p"/api/v1/rooms", body)

  defp leave(user), do: :ok = RoomManager.leave_room(user.id)

  defp events(user),
    do: Repo.all(from e in Event, where: e.user_id == ^user.id, order_by: e.id, select: e.kind)

  describe "GET /api/v1/auth/me" do
    test "carries the ads decision; an ad-aware read counts one offer per needed game",
         %{conn: conn} do
      user = due_adult()

      for path <- [
            "/api/v1/auth/me",
            "/api/v1/auth/me?ads_aware=true",
            "/api/v1/auth/me?ads_aware=true"
          ] do
        ads = conn |> as_user(user) |> get(path) |> json_response(200)

        assert ads["data"]["ads"] == %{
                 "eligible" => true,
                 "next_game_needs_ad" => true,
                 "games_until_ad" => 0,
                 "free_games_left" => 0
               }
      end

      assert events(user) == ["offered"]
    end

    test "with the kill switch off says no ad and counts nothing", %{conn: conn} do
      user = due_adult()
      Settings.put(:ads_enabled, false)

      data = json_response(conn |> as_user(user) |> get(~p"/api/v1/auth/me"), 200)["data"]

      assert data["ads"] == %{
               "eligible" => false,
               "next_game_needs_ad" => false,
               "games_until_ad" => 0,
               "free_games_left" => 0
             }

      assert data["user"]["id"] == user.id
      assert events(user) == []
    end

    test "a minor is never eligible", %{conn: conn} do
      ads =
        conn
        |> as_user(due_adult("13_17"))
        |> get(~p"/api/v1/auth/me")
        |> json_response(200)
        |> get_in(["data", "ads"])

      assert ads["eligible"] == false
    end
  end

  describe "POST /api/v1/rooms" do
    test "an ad-aware solo room without a credit answers 402 AD_REQUIRED with the decision" do
      user = due_adult()
      body = json_response(create_room(user, Map.put(@solo, "ads_aware", true)), 402)

      assert body == %{
               "error" => "AD_REQUIRED",
               "error_code" => "ad_required",
               "error_params" => %{},
               "ads" => %{
                 "eligible" => true,
                 "next_game_needs_ad" => true,
                 "games_until_ad" => 0,
                 "free_games_left" => 0
               }
             }

      assert {:error, :not_in_room} = RoomManager.leave_room(user.id)
      assert events(user) == ["offered"]
    end

    test "without ads_aware, as 3.2.4 sends it, a due solo room is never blocked" do
      user = due_adult()
      assert json_response(create_room(user, @solo), 201)
      leave(user)
      assert json_response(create_room(user, Map.put(@solo, "ads_aware", false)), 201)
      assert events(user) == []
    end

    test "a table with people is never blocked, ads_aware or not" do
      user = due_adult()
      body = %{"seats" => %{"seat_2" => "ai"}, "ads_aware" => true}
      assert json_response(create_room(user, body), 201)
    end

    test "a watched ad admits a retried create; the solo game's start uses it up" do
      user = due_adult()
      assert response(build_conn() |> as_user(user) |> post(~p"/api/v1/me/ads/watched"), 204)

      assert json_response(create_room(user, Map.put(@solo, "ads_aware", true)), 201)
      leave(user)
      assert json_response(create_room(user, Map.put(@solo, "ads_aware", true)), 201)
      leave(user)

      :ok = Profiles.count_solo_start(user.id)
      PidroServer.DataCase.await_tasks()

      Repo.update_all(from(p in Profiles.PlayerProfile, where: p.user_id == ^user.id),
        set: [solo_games_started: 5]
      )

      assert json_response(create_room(user, Map.put(@solo, "ads_aware", true)), 402)
    end

    test "an unavailable ad admits the solo room too, counted as unavailable" do
      user = due_adult()
      assert response(build_conn() |> as_user(user) |> post(~p"/api/v1/me/ads/unavailable"), 204)
      assert json_response(create_room(user, Map.put(@solo, "ads_aware", true)), 201)
      assert events(user) == ["unavailable"]
    end

    test "ads_aware must be a boolean" do
      user = due_adult()
      body = json_response(create_room(user, Map.put(@solo, "ads_aware", "yes")), 422)
      assert [%{"code" => "ads_aware"}] = body["errors"]
    end
  end

  test "POST /api/v1/me/ads/dismissed is counted and gives no credit" do
    user = due_adult()
    assert response(build_conn() |> as_user(user) |> post(~p"/api/v1/me/ads/dismissed"), 204)
    assert json_response(create_room(user, Map.put(@solo, "ads_aware", true)), 402)
    assert events(user) == ["dismissed", "offered"]
  end

  test "the ad endpoints need a signed-in user", %{conn: conn} do
    for kind <- ~w(watched unavailable dismissed) do
      assert json_response(post(conn, "/api/v1/me/ads/#{kind}"), 401)
    end
  end
end
