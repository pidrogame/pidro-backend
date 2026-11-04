# DEV_DATABASE=pidro_leagues_demo mix ecto.create
# DEV_DATABASE=pidro_leagues_demo mix ecto.migrate
# DEV_DATABASE=pidro_leagues_demo mix run apps/pidro_server/priv/repo/seeds/leagues_demo.exs
# Append --reset to restore the demo after playing, hiding or acknowledging results.
# Stop the demo server before resetting; replay holds the league lock for about two minutes.
if Mix.env() != :dev, do: raise("League demo is dev only")
alias PidroServer.{Admins, Leagues, Profiles, Progression, Repo, Stats}
alias PidroServer.Accounts.{Auth, User}
alias PidroServer.Admins.Admin
alias PidroServer.Friends.Friendship
alias PidroServer.Games.Room.Seat
alias PidroServer.Leagues.{Membership, Player, Result, Ribbons, Room}
alias PidroServer.Profiles.{Achievement, GameXp, PlayerProfile}
alias PidroServer.Stats.GameStats
import Ecto.Query
Logger.configure(level: :warning)

unless Repo.config()[:database] == "pidro_leagues_demo",
  do: raise("Use DEV_DATABASE=pidro_leagues_demo; this seed owns its disposable database")

# This standalone seed drives historical closes itself, without a competing minute tick.
:ok = Supervisor.terminate_child(PidroServer.Supervisor, PidroServer.Leagues.Closer)

password = "LeagueDemo2026!"

users =
  for i <- 1..72 do
    email = "league#{i}@demo.pidro.local"

    user =
      Repo.get_by(User, email: email) ||
        elem(
          Auth.register_user(%{email: email, username: "league#{i}", password: password}),
          1
        )

    # Seats and leagues use public_name; self-profile uses username. Keep them equal.
    user |> Ecto.Changeset.change(display_name: nil) |> Repo.update!()
  end

known = hd(users)
{starts, _closes} = Leagues.week(DateTime.utc_now())
now = DateTime.utc_now()

guest =
  Repo.get_by(User, display_name: "League guest") ||
    elem(Auth.create_guest_user(%{display_name: "League guest"}, []), 1)

prefix = "league-demo-v2-#{DateTime.to_unix(starts)}"

if "--reset" in System.argv() or is_nil(Repo.get_by(GameStats, room_code: prefix <> "-hidden-1")) do
  {:ok, _} =
    Repo.transaction(
      fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(350, 0)")
        # This named database is disposable. Upgrade old fixtures, or explicitly reset.
        Repo.delete_all(Membership)
        Repo.delete_all(Room)
        Repo.delete_all(Result)
        Repo.delete_all("league_weeks")
        Repo.delete_all(Player)

        ids = Enum.map([guest | users], & &1.id)

        Repo.delete_all(
          from g in GameStats,
            where: fragment("? && ?", g.player_ids, type(^ids, {:array, :binary_id}))
        )

        Repo.delete_all(from p in PlayerProfile, where: p.user_id in ^ids)
        Repo.delete_all(from a in Achievement, where: a.user_id in ^ids)

        play = fn user, points, at, key ->
          # Spread the target across plausible winning scores (62–73), not fake XP rows.
          count = div(points, Progression.xp_for_game(62, true))
          award = div(points, count)

          for i <- 1..count do
            xp = award + if(i <= rem(points, count), do: 1, else: 0)
            score = 62 + xp - Progression.xp_for_game(62, true)

            room = %{
              code: "#{prefix}-#{key}-#{i}",
              created_at: DateTime.add(at, -300),
              seats: %{
                north: Seat.new_human(:north, user.id),
                east: Seat.new_human(:east, guest.id),
                south: Seat.new_bot(:south, nil),
                west: Seat.new_bot(:west, nil)
              }
            }

            {:ok, _} =
              Stats.save_completed_game(
                room,
                :north_south,
                %{north_south: score, east_west: 40},
                nil,
                completed_at: at
              )
          end
        end

        seed_room = fn league, members, at, key ->
          for {user, i} <- Enum.with_index(members) do
            Repo.insert!(%Player{user_id: user.id, league: league},
              on_conflict: [set: [league: league]],
              conflict_target: [:user_id]
            )

            play.(user, 3000 - i * 60, at, "#{key}-#{user.username}")
          end
        end

        # Four finished months, then last week, all credited and settled by real paths.
        for offset <- 4..1//-1 do
          month =
            Date.utc_today()
            |> Date.beginning_of_month()
            |> Date.shift(month: -offset)
            |> Calendar.strftime("%Y-%m")

          at = month |> Ribbons.closes() |> hd()

          Repo.insert!(%Player{user_id: known.id, league: "ten"},
            on_conflict: [set: [league: "ten"]],
            conflict_target: [:user_id]
          )

          play.(known, 112, DateTime.add(at, -3600), "history-#{month}")
          {:ok, _} = Leagues.close(at, DateTime.add(at, 120))
        end

        last_week = DateTime.add(starts, -172_800)
        seed_room.("ten", Enum.take(users, 30), last_week, "last-ten")

        for {league, offset} <- [{"deuce", 30}, {"jack", 40}, {"ace", 50}, {"pidro", 60}],
            do: seed_room.(league, Enum.slice(users, offset, 10), last_week, "last-#{league}")

        play.(Enum.at(users, 70), 112, last_week, "not-placed")

        {:ok, _} = Leagues.close(starts, DateTime.add(starts, 120))

        # Known account is sixth, with an unseen promotion from Ten to Jack.
        jack = Enum.slice(users, 1, 5) ++ [known] ++ Enum.slice(users, 6, 24)
        seed_room.("jack", jack, now, "current-jack")

        for {league, offset} <- [{"deuce", 30}, {"ten", 40}, {"ace", 50}, {"pidro", 60}],
            do: seed_room.(league, Enum.slice(users, offset, 10), now, "current-#{league}")

        Repo.insert!(%Player{user_id: Enum.at(users, 71).id, hidden: true})
        play.(Enum.at(users, 71), 112, now, "hidden")
        Repo.update_all(from(r in Result, where: r.week_closes_at < ^starts), set: [seen_at: now])

        for friend <- Enum.slice(users, 40, 2), {a, b} <- [{known, friend}, {friend, known}] do
          Repo.insert!(%Friendship{user_id: a.id, friend_id: b.id}, on_conflict: :nothing)
        end
      end,
      timeout: :infinity
    )
end

admin_email = "leagues-admin@demo.pidro.local"

unless Admins.get_admin_by_email(admin_email) do
  %Admin{}
  |> Admin.registration_changeset(%{email: admin_email, password: password},
    force_password_change: false
  )
  |> Repo.insert!()
end

directory = Path.expand("../league_samples", __DIR__ <> "/..")
File.mkdir_p!(directory)

samples = [
  {"placed", known},
  {"not_placed", Enum.at(users, 70)},
  {"opted_out", Enum.at(users, 71)},
  {"guest", guest},
  {"pending_up", known},
  {"pending_stayed", Enum.at(users, 54)},
  {"pending_down", Enum.at(users, 49)}
]

for {name, user} <- samples do
  File.write!(
    Path.join(directory, name <> ".json"),
    Jason.encode!(Leagues.show(user), pretty: true) <> "\n"
  )
end

start = Leagues.start_at()
Application.put_env(:pidro_server, :leagues_start_at, nil)

File.write!(
  Path.join(directory, "off.json"),
  Jason.encode!(Leagues.show(known), pretty: true) <> "\n"
)

Application.put_env(:pidro_server, :leagues_start_at, start)

data = Leagues.show(known)
true = data.league == "jack" and data.me.place == 6 and data.room.size == 30
true = data.pending_result.move == "up" and length(data.ribbons.past) == 4

true =
  Enum.find(data.room.standings, & &1.me).username == Profiles.public_profile(known.id).username

# Check every seeded membership against the same counting-game ledger as production.
for member <- Repo.all(Membership) do
  total =
    Repo.one(
      from x in GameXp,
        join: g in GameStats,
        on: g.id == x.game_stats_id,
        where:
          x.user_id == ^member.user_id and
            g.completed_at >= ^DateTime.add(member.closes_at, -604_800) and
            g.completed_at < ^member.closes_at and fragment("cardinality(?) >= 2", g.player_ids),
        select: sum(x.xp)
    )

  true = member.points == total
end

for user <- users do
  profile = Repo.get_by!(PlayerProfile, user_id: user.id)
  total = Repo.aggregate(from(x in GameXp, where: x.user_id == ^user.id), :sum, :xp)
  games = Repo.aggregate(from(g in GameStats, where: ^user.id in g.player_ids), :count)
  true = profile.veteran_xp == total and profile.games_played == games
  true = profile.veteran_level == Progression.level_for_xp(total)
end

IO.puts("League demo: #{length(users)} registered players + one guest; five leagues")
IO.puts("Every membership point and all 72 registered profiles come from real two-human games.")

for user <- [known, Enum.at(users, 70), Enum.at(users, 71)] do
  profile = Repo.get_by!(PlayerProfile, user_id: user.id)
  periods = Profiles.xp_periods(user.id)

  IO.puts(
    "#{user.username}: #{profile.games_played} games, Level #{profile.veteran_level}, " <>
      "#{profile.veteran_xp} all-time XP, #{periods.this_week} profile-week XP, #{periods.this_month} month XP"
  )
end

IO.puts(
  "Known account: league1@demo.pidro.local / #{password}; Jack, 6th of 30, unseen up, four past ribbons"
)

IO.puts(
  "Not placed: league71@demo.pidro.local; opted out: league72@demo.pidro.local (same password)"
)

IO.puts("Admin: #{admin_email} / #{password}; /dev/leagues")
IO.puts("Guest: #{guest.id}; create a fresh guest through POST /api/v1/auth/guest to sign in")
IO.puts("Samples: #{directory}")
