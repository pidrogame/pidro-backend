defmodule PidroServerWeb.API.ProfileControllerTest do
  use PidroServerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PidroServer.Accounts.Token
  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Profiles
  alias PidroServer.Stats
  alias PidroServer.Repo

  defp auth(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
  end

  defp put_profile(user, fields) do
    {:ok, _profile} = Profiles.get_or_create_profile(user.id)

    from(p in PidroServer.Profiles.PlayerProfile, where: p.user_id == ^user.id)
    |> Repo.update_all(set: fields)
  end

  defp shared_game(seats, winner) do
    results =
      Map.new(seats, fn seat ->
        {user, position, participation} =
          case seat do
            {user, position} -> {user, position, :played}
            seat -> seat
          end

        team = if position in [:north, :south], do: :north_south, else: :east_west
        result = if team == winner, do: :win, else: :loss
        {user.id, %{participation: participation, result: result, team: team, position: position}}
      end)

    %PidroServer.Stats.GameStats{}
    |> PidroServer.Stats.GameStats.changeset(%{
      room_code: "TOGE",
      completed_at: DateTime.utc_now(),
      winner: winner,
      player_ids: Map.keys(results),
      player_results: results
    })
    |> Repo.insert!()
  end

  describe "show/2" do
    test "authed request returns all profile sections", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      for key <- [
            "user_id",
            "games_played",
            "wins",
            "losses",
            "win_rate",
            "first_seen_at",
            "account_age_days",
            "skill",
            "veteran",
            "heritage",
            "classic",
            "playstyle",
            "achievements",
            "achievements_catalog"
          ] do
        assert Map.has_key?(data, key), "expected key #{key} in profile payload"
      end

      assert Map.has_key?(data["skill"], "tier")
      assert Map.has_key?(data["skill"], "provisional")
      assert data["veteran"]["level"] != nil
      assert Map.has_key?(data["playstyle"], "avg_winning_bid")
      assert data["username"] == user.username
      assert data["display_name"] == user.display_name
      assert Map.has_key?(data, "avatar_url")
      assert Map.has_key?(data, "bio")
    end

    test "raw rating internals are ABSENT from the payload (security contract)", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      refute Map.has_key?(data, "rating_mu")
      refute Map.has_key?(data, "rating_sigma")
      refute Map.has_key?(data, "rating_games_count")
      refute Map.has_key?(data, "heritage_flags")
      refute Map.has_key?(data, "playstyle_bidding_wins")
      refute Map.has_key?(data, "playstyle_bidding_attempts")

      # Not smuggled inside the skill object either.
      refute Map.has_key?(data["skill"], "rating_mu")
      refute Map.has_key?(data["skill"], "rating_sigma")
      refute Map.has_key?(data["skill"], "rating_games_count")
    end

    test "skill exposes a tier string in the enum and a boolean provisional", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      skill = json_response(conn, 200)["data"]["skill"]

      assert skill["tier"] in ["provisional", "bronze", "silver", "gold", "platinum", "master"]
      assert is_boolean(skill["provisional"])
    end

    test "unauthenticated request returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/profile")
      assert json_response(conn, 401)
    end

    test "fresh / never-played user gets sane defaults and provisional skill", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      assert data["games_played"] == 0
      assert data["win_rate"] == 0.0
      assert data["xp"] == %{"this_week" => 0, "this_month" => 0}
      assert data["record"] == %{"games" => 0, "wins" => 0, "losses" => 0, "win_rate" => 0.0}
      assert data["skill"] == %{"tier" => "provisional", "provisional" => true}
      assert data["heritage"] == []
      assert data["classic"] == nil
      assert data["playstyle"]["bidding_win_rate"] == nil
      assert data["playstyle"]["aggression_insufficient"] == true
      assert data["achievements"] == []
    end

    test "migrated user shows veteran progression, heritage badges, and Classic career", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture()

      {:ok, _profile} =
        Profiles.import_legacy_progression(user, %{
          xp: 9_999,
          founding_member: true,
          classic_username: "Veteran",
          classic_name_allowed: true,
          classic_level: 42,
          legacy_played_games: 100,
          legacy_victories: 61,
          legacy_losses: 39,
          games_played_counter: 20,
          wins: 12,
          losses: 8,
          member_since: "2013-04-12T09:30:00Z"
        })

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      assert data["veteran"]["level"] > 0
      assert data["veteran"]["xp"] == 9_999
      assert data["veteran"]["title"] != nil

      heritage_keys = Enum.map(data["heritage"], & &1["key"])
      assert "played_pidro_one" in heritage_keys
      assert "founding_member" in heritage_keys

      assert data["classic"] == %{
               "games_played" => 120,
               "level" => 42,
               "losses" => 47,
               "member_since" => "2013-04-12T09:30:00Z",
               "name" => "Veteran",
               "win_rate" => 73 / 120,
               "wins" => 73
             }

      # Importing Classic history does not seed rating, so skill stays provisional.
      assert data["skill"]["provisional"] == true
    end

    test "the record adds Classic games to Pidro 2 games; Classic XP is lifetime only", %{
      conn: conn
    } do
      classic = AccountsFixtures.user_fixture()
      newcomer = AccountsFixtures.user_fixture()

      {:ok, _profile} =
        Profiles.import_legacy_progression(classic, %{
          xp: 9_999,
          legacy_played_games: 100,
          legacy_victories: 61,
          legacy_losses: 39
        })

      for user <- [classic, newcomer] do
        {:ok, _profile} = Profiles.get_or_create_profile(user.id)

        from(p in PidroServer.Profiles.PlayerProfile, where: p.user_id == ^user.id)
        |> Repo.update_all(set: [games_played: 5, wins: 2, losses: 3])
      end

      data = conn |> auth(classic) |> get(~p"/api/v1/profile") |> json_response(200)
      data = data["data"]

      assert data["record"] == %{
               "games" => 105,
               "wins" => 63,
               "losses" => 42,
               "win_rate" => 63 / 105
             }

      assert data["veteran"]["xp"] == 9_999
      assert data["xp"] == %{"this_week" => 0, "this_month" => 0}

      data = build_conn() |> auth(newcomer) |> get(~p"/api/v1/profile") |> json_response(200)

      assert data["data"]["record"] == %{
               "games" => 5,
               "wins" => 2,
               "losses" => 3,
               "win_rate" => 0.4
             }
    end

    test "this week's and this month's XP come from completed games", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      seats = %{north: Seat.new_human(:north, user.id), east: Seat.new_human(:east, other.id)}
      room = %{code: "XPWK", created_at: DateTime.utc_now(), seats: seats}

      {:ok, _summaries} =
        Stats.save_completed_game(room, :north_south, %{north_south: 62, east_west: 45})

      data = conn |> auth(user) |> get(~p"/api/v1/profile") |> json_response(200)
      earned = data["data"]["veteran"]["xp"]

      assert earned > 0
      assert data["data"]["xp"] == %{"this_week" => earned, "this_month" => earned}
    end
  end

  describe "PATCH /api/v1/profile" do
    test "creates, normalizes, omits, and clears only the caller's bio", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{display_name: "Owner"})
      other = AccountsFixtures.user_fixture(%{display_name: "Other"})

      assert %{"data" => %{"bio" => "first\nsecond"}} =
               conn
               |> auth(user)
               |> patch(~p"/api/v1/profile", %{
                 "bio" => "\uFEFF first\r\nsecond \u3000",
                 "user_id" => other.id,
                 "display_name" => "Hacked",
                 "email" => "private@example.com"
               })
               |> json_response(200)

      assert Repo.get!(PidroServer.Accounts.User, user.id).display_name == "Owner"
      assert Repo.get!(PidroServer.Accounts.User, other.id).bio == nil

      assert %{"data" => %{"bio" => "first\nsecond"}} =
               build_conn() |> auth(user) |> patch(~p"/api/v1/profile", %{}) |> json_response(200)

      assert %{"data" => %{"bio" => nil}} =
               build_conn()
               |> auth(user)
               |> patch(~p"/api/v1/profile", %{"bio" => " \t\r\n\u00A0"})
               |> json_response(200)
    end

    test "counts Unicode scalars, preserves Unicode and rejects invalid values" do
      user = AccountsFixtures.user_fixture()
      zwj_sequence = "👩‍👩‍👧‍👦"
      combining = "e\u0301"

      for bio <- [
            String.duplicate("a", 280),
            String.duplicate("界", 280),
            String.duplicate("😀", 280)
          ] do
        assert %{"data" => %{"bio" => ^bio}} =
                 build_conn()
                 |> auth(user)
                 |> patch(~p"/api/v1/profile", %{"bio" => bio})
                 |> json_response(200)
      end

      preserved = "\u0085\u200B#{zwj_sequence}#{combining}\u0085\u200B"

      assert %{"data" => %{"bio" => ^preserved}} =
               build_conn()
               |> auth(user)
               |> patch(~p"/api/v1/profile", %{"bio" => preserved})
               |> json_response(200)

      for invalid <- [String.duplicate("a", 281), "has\0nul", 12, true, %{}, []] do
        response =
          build_conn()
          |> auth(user)
          |> patch(~p"/api/v1/profile", %{"bio" => invalid})
          |> json_response(422)

        assert response["error_code"] == "validation_failed"
        assert response["error_params"] == %{}

        assert [%{"field" => "bio", "error_code" => code, "error_params" => _}] =
                 response["field_errors"]

        assert code in ["field_invalid", "field_too_long"]
      end

      refute PidroServer.Accounts.User.bio_changeset(user, %{bio: <<255>>}).valid?
    end
  end

  describe "GET /api/v1/profiles/:id" do
    test "returns the exact public allowlist to registered and guest callers" do
      owner = AccountsFixtures.user_fixture(%{display_name: "Public Name"})
      guest = AccountsFixtures.guest_fixture()
      {:ok, _} = Auth.update_bio(owner.id, %{bio: "Public bio"})

      for caller <- [AccountsFixtures.user_fixture(), guest] do
        data =
          build_conn()
          |> auth(caller)
          |> get(~p"/api/v1/profiles/#{owner.id}")
          |> json_response(200)
          |> Map.fetch!("data")

        assert Map.keys(data) |> Enum.sort() ==
                 ~w(avatar_url bio classic display_name level medals pin prestige record title together user_id username)a
                 |> Enum.map(&Atom.to_string/1)
                 |> Enum.sort()

        assert data["user_id"] == owner.id
        assert data["username"] == owner.username
        assert data["display_name"] == "Public Name"
        assert data["bio"] == "Public bio"
        refute Map.has_key?(data, "email")
        refute Map.has_key?(data, "token")
      end
    end

    test "the player sheet: a Legend, a level-12 player, a Classic claimer and a guest" do
      viewer = AccountsFixtures.user_fixture()
      legend = AccountsFixtures.user_fixture()
      regular = AccountsFixtures.user_fixture()
      classic = AccountsFixtures.user_fixture()
      guest = AccountsFixtures.guest_fixture()

      put_profile(legend, veteran_xp: 2_800_000)
      put_profile(regular, veteran_xp: 11_520, games_played: 8, wins: 6, losses: 2)
      :awarded = Profiles.award_achievement(legend.id, :player)
      :awarded = Profiles.award_achievement(legend.id, :winner)

      {:ok, _} =
        Profiles.import_legacy_progression(classic, %{
          xp: 9_999,
          classic_username: "Veteran",
          classic_name_allowed: true,
          legacy_played_games: 100,
          legacy_victories: 61,
          legacy_losses: 39,
          games_played_counter: 20,
          wins: 12,
          losses: 8,
          member_since: "2013-04-12T09:30:00Z"
        })

      put_profile(classic, games_played: 5, wins: 2, losses: 3)

      sheet = fn user ->
        response =
          build_conn()
          |> auth(viewer)
          |> get(~p"/api/v1/profiles/#{user.id}")
          |> json_response(200)

        OpenApiSpex.TestAssertions.assert_schema(
          response,
          "Public Profile Response",
          PidroServerWeb.ApiSpec.spec()
        )

        Map.drop(response["data"], ~w(user_id username display_name avatar_url bio))
      end

      no_games = %{"games" => 0, "won_as_partners" => 0, "against_games" => 0, "against_won" => 0}

      assert sheet.(legend) == %{
               "level" => 100,
               "prestige" => 4,
               "title" => "Legend",
               "pin" => nil,
               "classic" => nil,
               "record" => %{"games" => 0, "win_rate" => 0.0},
               "medals" => 2,
               "together" => no_games
             }

      assert sheet.(regular) == %{
               "level" => 12,
               "prestige" => 0,
               "title" => "Journeyman",
               "pin" => nil,
               "classic" => nil,
               "record" => %{"games" => 8, "win_rate" => 0.75},
               "medals" => 0,
               "together" => no_games
             }

      # Classic 100 old + 20 counted games (61 + 12 won) plus 5 Pidro 2 games (2 won).
      assert sheet.(classic) == %{
               "level" => PidroServer.Progression.level_for_xp(9_999),
               "prestige" => 0,
               "title" =>
                 PidroServer.Progression.title_for_level(
                   PidroServer.Progression.level_for_xp(9_999)
                 ),
               "pin" => "classic",
               "classic" => %{
                 "username" => "Veteran",
                 "member_since" => "2013-04-12T09:30:00Z",
                 "games_played" => 120
               },
               "record" => %{"games" => 125, "win_rate" => 0.6},
               "medals" => 0,
               "together" => no_games
             }

      assert sheet.(guest) == %{
               "level" => 1,
               "prestige" => 0,
               "title" => "Rookie",
               "pin" => nil,
               "classic" => nil,
               "record" => %{"games" => 0, "win_rate" => 0.0},
               "medals" => 0,
               "together" => no_games
             }

      # Reading a sheet creates no profile row for a player who has none.
      refute Repo.get_by(PidroServer.Profiles.PlayerProfile, user_id: guest.id)
    end

    test "together counts shared Pidro 2 games from the viewer's side, in one query" do
      [me, them, other, fourth] = for _ <- 1..4, do: AccountsFixtures.user_fixture()
      guest = AccountsFixtures.guest_fixture()

      # Partners won, partners lost, then three against each other: I win two, they win one.
      shared_game([{me, :north}, {them, :south}, {other, :east}, {fourth, :west}], :north_south)
      shared_game([{me, :east}, {them, :west}, {other, :north}], :north_south)
      shared_game([{me, :north}, {them, :east}], :north_south)
      shared_game([{me, :west}, {them, :south}, {other, :north}], :east_west)
      shared_game([{me, :north}, {them, :west}, {fourth, :south}], :east_west)
      # Not together: each with someone else.
      shared_game([{me, :north}, {other, :south}], :north_south)
      shared_game([{them, :north}, {fourth, :east}], :north_south)
      # They took over my seat after I left: we never sat together.
      shared_game([{me, :north, :abandoned}, {them, :north, :substitute}], :north_south)
      # A guest viewer partnered them once and won.
      shared_game([{guest, :east}, {them, :west}], :east_west)

      together = fn viewer, user ->
        build_conn()
        |> auth(viewer)
        |> get(~p"/api/v1/profiles/#{user.id}")
        |> json_response(200)
        |> get_in(["data", "together"])
      end

      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:pidro_server, :repo, :query],
        fn _, _, meta, owner ->
          if meta.source == "game_stats", do: send(owner, :game_stats_query)
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert together.(me, them) == %{
               "games" => 5,
               "won_as_partners" => 1,
               "against_games" => 3,
               "against_won" => 2
             }

      assert_received :game_stats_query
      refute_received :game_stats_query

      assert together.(them, me) == %{
               "games" => 5,
               "won_as_partners" => 1,
               "against_games" => 3,
               "against_won" => 1
             }

      assert together.(me, me) == %{
               "games" => 0,
               "won_as_partners" => 0,
               "against_games" => 0,
               "against_won" => 0
             }

      assert together.(guest, them) == %{
               "games" => 1,
               "won_as_partners" => 1,
               "against_games" => 0,
               "against_won" => 0
             }
    end

    test "missing and malformed UUIDs are 404 and authentication is required", %{conn: conn} do
      caller = AccountsFixtures.user_fixture()

      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        assert build_conn()
               |> auth(caller)
               |> get("/api/v1/profiles/#{id}")
               |> json_response(404)
      end

      assert conn |> get(~p"/api/v1/profiles/#{caller.id}") |> json_response(401)
    end

    test "guest upgrade preserves the bio on the same row" do
      guest = AccountsFixtures.guest_fixture()
      {:ok, _} = Auth.update_bio(guest.id, %{bio: "Keep me"})

      assert {:ok, upgraded} =
               Auth.upgrade_guest(guest, %{email: "upgrade@example.com", password: "long-enough"})

      assert upgraded.id == guest.id
      assert Repo.get!(PidroServer.Accounts.User, guest.id).bio == "Keep me"
    end
  end

  describe "GET /api/v1/players/by-slug/:slug" do
    test "returns the same public profile as /profiles/:id" do
      owner = AccountsFixtures.user_fixture(%{username: "Bengt Åberg", display_name: "Bengt"})
      caller = AccountsFixtures.guest_fixture()

      data =
        build_conn()
        |> auth(caller)
        |> get(~p"/api/v1/players/by-slug/bengt-aberg")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data ==
               build_conn()
               |> auth(caller)
               |> get(~p"/api/v1/profiles/#{owner.id}")
               |> json_response(200)
               |> Map.fetch!("data")

      assert data["user_id"] == owner.id
    end

    test "an unknown slug is 404 and authentication is required", %{conn: conn} do
      caller = AccountsFixtures.user_fixture()

      for slug <- ["nobody-here", "Bengt%20Aberg"] do
        assert build_conn()
               |> auth(caller)
               |> get("/api/v1/players/by-slug/#{slug}")
               |> json_response(404)
      end

      assert conn |> get(~p"/api/v1/players/by-slug/#{caller.share_slug}") |> json_response(401)
    end
  end
end
