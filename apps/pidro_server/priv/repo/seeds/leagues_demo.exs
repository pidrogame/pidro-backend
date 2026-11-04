# DEV_DATABASE=pidro_leagues_demo mix ecto.create
# DEV_DATABASE=pidro_leagues_demo mix ecto.migrate
# DEV_DATABASE=pidro_leagues_demo mix run apps/pidro_server/priv/repo/seeds/leagues_demo.exs
if Mix.env() != :dev, do: raise("League demo is dev only")
alias PidroServer.{Admins, Leagues, Repo, Stats}
alias PidroServer.Accounts.{Auth, User}
alias PidroServer.Admins.Admin
alias PidroServer.Friends.Friendship
alias PidroServer.Games.Room.Seat
alias PidroServer.Leagues.{Membership, Player, Result, Ribbons, Room}
import Ecto.Query
Logger.configure(level: :warning)

unless Repo.config()[:database] == "pidro_leagues_demo",
  do: raise("Use DEV_DATABASE=pidro_leagues_demo; this seed owns its disposable database")

password = "LeagueDemo2026!"
names = ~w(Mirja Antti Jocke Aino Eero Sanna Olli Leena Mika Tuula)

users =
  for i <- 1..72 do
    email = "league#{i}@demo.pidro.local"

    Repo.get_by(User, email: email) ||
      elem(
        Auth.register_user(%{
          email: email,
          username: "league#{i}",
          display_name: "#{Enum.at(names, rem(i - 1, 10))} #{i}",
          password: password
        }),
        1
      )
  end

known = hd(users)
{starts, closes} = Leagues.week(DateTime.utc_now())
now = DateTime.utc_now()

guest =
  Repo.get_by(User, display_name: "League guest") ||
    elem(Auth.create_guest_user(%{display_name: "League guest"}, []), 1)

unless Repo.get_by(Membership, user_id: known.id, closes_at: closes) do
  {:ok, _} =
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(350, 0)")
      # This named database is disposable. Rebuild only when its week changes.
      Repo.delete_all(Membership)
      Repo.delete_all(Room)
      Repo.delete_all(Result)
      Repo.delete_all("league_weeks")
      Repo.delete_all(Player)

      seed_room = fn league, members, close ->
        room =
          Repo.insert!(%Room{
            league: league,
            starts_at: DateTime.add(close, -604_800),
            closes_at: close
          })

        for {user, i} <- Enum.with_index(members) do
          Repo.insert!(%Player{user_id: user.id, league: league},
            on_conflict: [set: [league: league]],
            conflict_target: [:user_id]
          )

          Repo.insert!(%Membership{
            room_id: room.id,
            user_id: user.id,
            closes_at: close,
            points: 3000 - i * 60,
            points_at: DateTime.add(now, -3600 + i),
            placed_at: DateTime.add(now, -7200 + i)
          })
        end

        room
      end

      # Four finished months with real settlement, followed by last week's Ten room.
      for offset <- 4..1//-1 do
        month =
          Date.utc_today()
          |> Date.beginning_of_month()
          |> Date.shift(month: -offset)
          |> Calendar.strftime("%Y-%m")

        at = month |> Ribbons.closes() |> hd()
        seed_room.("ten", [known], at)
        {:ok, _} = Leagues.close(at, DateTime.add(at, 120))
      end

      seed_room.("ten", Enum.take(users, 30), starts)

      for {league, offset} <- [{"deuce", 30}, {"jack", 40}, {"ace", 50}, {"pidro", 60}],
          do: seed_room.(league, Enum.slice(users, offset, 10), starts)

      {:ok, _} = Leagues.close(starts, DateTime.add(starts, 120))

      # Known account is sixth, with an unseen promotion from Ten to Jack.
      jack = Enum.slice(users, 1, 5) ++ [known] ++ Enum.slice(users, 6, 24)
      seed_room.("jack", jack, closes)

      for {league, offset} <- [{"deuce", 30}, {"ten", 40}, {"ace", 50}, {"pidro", 60}],
          do: seed_room.(league, Enum.slice(users, offset, 10), closes)

      Repo.insert!(%Player{user_id: Enum.at(users, 71).id, hidden: true})
      Repo.update_all(from(r in Result, where: r.week_closes_at < ^starts), set: [seen_at: now])

      for friend <- Enum.slice(users, 40, 2), {a, b} <- [{known, friend}, {friend, known}] do
        Repo.insert!(%Friendship{user_id: a.id, friend_id: b.id}, on_conflict: :nothing)
      end
    end)
end

# Real completion path, idempotent game ids: XP and league points are written together.
for i <- 1..11 do
  [a, b] = Enum.slice(users, 40, 2)

  seats = %{
    north: Seat.new_human(:north, a.id),
    east: Seat.new_human(:east, b.id),
    south: Seat.new_bot(:south, nil),
    west: Seat.new_bot(:west, nil)
  }

  room = %{
    code: "league-demo-#{DateTime.to_unix(starts)}-#{i}",
    created_at: DateTime.add(now, -300),
    seats: seats
  }

  Stats.save_completed_game(room, :north_south, %{north_south: 62, east_west: 40})
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
IO.puts("League demo: #{length(users)} registered players + one guest; five leagues")

IO.puts(
  "Known account: league1@demo.pidro.local / #{password}; Jack, 6th of 30, unseen up, four past ribbons"
)

IO.puts(
  "Not placed: league71@demo.pidro.local; opted out: league72@demo.pidro.local (same password)"
)

IO.puts("Admin: #{admin_email} / #{password}; /dev/leagues")
IO.puts("Guest: #{guest.id}; create a fresh guest through POST /api/v1/auth/guest to sign in")
IO.puts("Samples: #{directory}")
