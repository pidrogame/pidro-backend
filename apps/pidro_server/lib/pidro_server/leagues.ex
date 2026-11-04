defmodule PidroServer.Leagues do
  @moduledoc "Weekly Sunday-to-Sunday leagues, independent of lifetime Level XP."
  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.Leagues.{Membership, Player, Result, Room}
  alias PidroServer.Repo

  @leagues ~w(deuce ten jack ace pidro)
  @bands %{
    "deuce" => {10, 0},
    "ten" => {7, 5},
    "jack" => {5, 5},
    "ace" => {3, 5},
    "pidro" => {0, 8}
  }
  @week_seconds 7 * 86_400

  @doc "League order, from bottom to top."
  def leagues, do: @leagues

  @doc "Runtime activation close; nil keeps production dark."
  def start_at, do: Application.get_env(:pidro_server, :leagues_start_at)

  @doc "Whether leagues are on at the supplied instant."
  def enabled?(now \\ DateTime.utc_now()) do
    case start_at() do
      %DateTime{} = start -> DateTime.compare(now, start) != :lt
      nil -> false
    end
  end

  @doc "The half-open UTC week containing an instant, including the Sunday close."
  def week(%DateTime{} = instant) do
    utc = DateTime.from_unix!(DateTime.to_unix(instant))
    date = DateTime.to_date(utc)
    sunday = Date.add(date, -rem(Date.day_of_week(date), 7))
    boundary = DateTime.new!(sunday, ~T[19:00:00], "Etc/UTC")

    starts =
      if DateTime.compare(utc, boundary) == :lt,
        do: DateTime.add(boundary, -@week_seconds),
        else: boundary

    {starts, DateTime.add(starts, @week_seconds)}
  end

  @doc "Scaled bands; positive halves round up, demotion gives way to promotion."
  def bands(league, n) when n >= 0 do
    {up, down} = Map.fetch!(@bands, to_string(league))
    promote = div(up * n + 15, 30)
    promote = if to_string(league) != "pidro" and n >= 2, do: max(1, promote), else: promote
    {promote, min(div(down * n + 15, 30), n - promote)}
  end

  @doc "Locks before profile writes, only for enabled, counting game completions."
  def prepare_game(nil, _results), do: false

  def prepare_game(game, results) do
    counting = enabled?() and enabled?(game.completed_at) and map_size(results) >= 2

    if counting do
      true = Repo.in_transaction?()
      lock()
    end

    counting
  end

  # All league mutations take this lock before any profile/player writes.
  # The small completion transaction stays atomic with close and grace transfers.
  defp lock, do: Repo.query!("SELECT pg_advisory_xact_lock(350, 0)")

  @doc "Adds the XP delta inside the already-locked completion transaction."
  def credit(user_id, xp, completed_at) do
    {starts, closes} = week(completed_at)
    member = membership(user_id, closes)

    cond do
      member ->
        from(m in Membership, where: m.id == ^member.id)
        |> Repo.update_all(inc: [points: xp], set: [points_at: DateTime.utc_now()])

      closed?(closes) or result?(user_id, closes) ->
        :ok

      Repo.exists?(from(u in User, where: u.id == ^user_id and not u.guest)) ->
        player = player(user_id)

        unless player.hidden do
          Repo.insert!(%Player{user_id: user_id}, on_conflict: :nothing)
          room = placement_room(player.league, {starts, closes}, completed_at)
          now = DateTime.utc_now()

          Repo.insert!(
            %Membership{
              user_id: user_id,
              room_id: room.id,
              closes_at: closes,
              points: xp,
              points_at: now,
              placed_at: now
            }, on_conflict: :nothing, conflict_target: [:closes_at, :user_id])
        end

      true ->
        :ok
    end
  end

  defp placement_room(league, {starts, closes}, at) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock($1::integer, $2::integer)",
      [351 + Enum.find_index(@leagues, &(&1 == league)), DateTime.to_unix(closes)]
    )

    # In the final 24 hours the last room grows to 40; otherwise rooms hold 30.
    capacity = if DateTime.diff(closes, at) <= 86_400, do: 40, else: 30

    room =
      Repo.one(
        from r in Room,
          where: r.league == ^league and r.closes_at == ^closes and is_nil(r.closed_at),
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 1
      )

    if room &&
         Repo.aggregate(from(m in Membership, where: m.room_id == ^room.id), :count) < capacity do
      room
    else
      Repo.insert!(%Room{league: league, starts_at: starts, closes_at: closes})
    end
  end

  @doc "One ordered query per room; UUID is the stable final tie-break."
  def standings(room_id) do
    Repo.all(
      from m in Membership,
        where: m.room_id == ^room_id,
        order_by: [desc: m.points, asc: m.points_at, asc: m.user_id]
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {member, place} -> Map.put(member, :place, place) end)
  end

  @doc "Stored preference, or the default Deuce row without writing on reads."
  def player(user_id), do: Repo.get(Player, user_id) || %Player{user_id: user_id}

  defp membership(user_id, closes),
    do: Repo.get_by(Membership, user_id: user_id, closes_at: closes)

  defp closed?(closes),
    do: Repo.exists?(from w in "league_weeks", where: w.closes_at == type(^closes, :utc_datetime))

  defp result?(user_id, closes),
    do:
      Repo.exists?(from r in Result, where: r.user_id == ^user_id and r.week_closes_at == ^closes)
end
