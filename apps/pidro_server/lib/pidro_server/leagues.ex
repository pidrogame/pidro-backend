defmodule PidroServer.Leagues do
  @moduledoc "Weekly Sunday-to-Sunday leagues, independent of lifetime Level XP."
  import Ecto.Query

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Blocks.Block
  alias PidroServer.Friends.Friendship
  alias PidroServer.Leagues.{Membership, Player, Result, Ribbons, Room}
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
            },
            on_conflict: :nothing,
            conflict_target: [:closes_at, :user_id]
          )
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

  @doc "Closes all due weeks in order; the claim and every outcome commit together."
  def close_due(now \\ DateTime.utc_now()) do
    if enabled?(now) do
      {latest, _} = week(DateTime.add(now, -120))
      close_through(latest, now)
    else
      {:ok, 0}
    end
  end

  @doc "Closes through a due Sunday. An early or disabled call does nothing."
  def close(closes, now \\ DateTime.utc_now()) do
    if enabled?(now) and enabled?(closes) and elem(week(closes), 0) == closes and
         DateTime.diff(now, closes) >= 120 do
      close_through(closes, now)
    else
      {:ok, 0}
    end
  end

  if Application.compile_env(:pidro_server, :dev_routes, false) do
    @doc "Dev-only manual close through a given Sunday, including a future demo close."
    def dev_close(closes) do
      if elem(week(closes), 0) == closes do
        close(closes, DateTime.add(closes, 120))
      else
        {:error, :invalid_close}
      end
    end
  end

  defp close_through(latest, now) do
    now = DateTime.from_unix!(DateTime.to_unix(now, :microsecond), :microsecond)

    Repo.transaction(fn ->
      lock()

      start_at()
      |> Stream.iterate(&DateTime.add(&1, @week_seconds))
      |> Enum.take_while(&(DateTime.compare(&1, latest) != :gt))
      |> Enum.reduce(0, fn closes, count -> count + close_week(closes, now) end)
    end)
  end

  defp close_week(closes, now) do
    {claimed, _} = Repo.insert_all("league_weeks", [%{closes_at: closes}], on_conflict: :nothing)

    if claimed == 1 do
      rooms = Repo.all(from r in Room, where: r.closes_at == ^closes, order_by: r.id)

      for room <- rooms do
        members = standings(room.id)
        for member <- members, do: settle(room, member, length(members), nil, now)
        Repo.update!(Ecto.Changeset.change(room, closed_at: now))
      end
    end

    claimed
  end

  defp settle(room, member, size, seen_at, now) do
    {promote, demote} = bands(room.league, size)
    index = Enum.find_index(@leagues, &(&1 == room.league))

    {move, step} =
      cond do
        member.place <= promote -> {"up", 1}
        member.place > size - demote -> {"down", -1}
        true -> {"stayed", 0}
      end

    new_league = Enum.at(@leagues, index + step)

    result = %Result{
      user_id: member.user_id,
      week_starts_at: room.starts_at,
      week_closes_at: room.closes_at,
      old_league: room.league,
      new_league: new_league,
      move: move,
      place: member.place,
      points: member.points,
      room_size: size,
      seen_at: seen_at
    }

    unless result?(member.user_id, room.closes_at) do
      history =
        Repo.all(
          from r in Result,
            where: r.user_id == ^member.user_id and r.week_closes_at < ^room.closes_at
        )

      month = Ribbons.month(room.closes_at)
      before = Ribbons.ribbon(history, month, room.closes_at)
      ribbon = Ribbons.ribbon([result | history], month, room.closes_at)
      ribbon = Map.put(ribbon, :changed, is_nil(before) or before.league != ribbon.league)
      Repo.insert!(%{result | ribbon: ribbon})
      put_player(member.user_id, league: new_league)
      if step != 0, do: transfer(member.user_id, new_league, room.closes_at, now)
    end
  end

  defp transfer(user_id, league, starts, now) do
    closes = DateTime.add(starts, @week_seconds)

    case membership(user_id, closes) do
      nil ->
        :ok

      member ->
        unless closed?(closes) do
          room = placement_room(league, {starts, closes}, now)
          Repo.update!(Ecto.Changeset.change(member, room_id: room.id))
        end
    end
  end

  @doc "Sets hiding atomically with an immediate seen outcome, except during Sunday grace."
  def hidden(%User{guest: true}, _hidden, _now), do: {:error, :account_required}

  def hidden(%User{} = user, hidden, now) do
    now = DateTime.from_unix!(DateTime.to_unix(now, :microsecond), :microsecond)

    changeset =
      %Player{}
      |> Ecto.Changeset.cast(%{hidden: hidden}, [:hidden])
      |> Ecto.Changeset.validate_required([:hidden])

    if changeset.valid? do
      hidden = Ecto.Changeset.get_field(changeset, :hidden)

      Repo.transaction(fn ->
        lock()
        {starts, closes} = week(now)
        member = membership(user.id, closes)

        if enabled?(now) and hidden and member do
          # Before activation there is no preceding league week to wait for.
          if DateTime.compare(starts, start_at()) != :gt or closed?(starts) do
            room = Repo.get!(Room, member.room_id)
            members = standings(room.id)
            ranked = Enum.find(members, &(&1.user_id == user.id))
            settle(room, ranked, length(members), now, now)
          end

          Repo.delete!(member)
        end

        put_player(user.id, hidden: hidden)
      end)
    else
      {:error, changeset}
    end
  end

  @doc "Records dismissal of the league introduction."
  def intro_seen(%User{guest: true}), do: {:error, :account_required}

  def intro_seen(%User{id: id}) do
    Repo.transaction(fn ->
      lock()
      put_player(id, intro_seen: true)
    end)
  end

  @doc "Acknowledges only the caller's result, idempotently."
  def seen(user_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Result{} <- Repo.get_by(Result, id: id, user_id: user_id) do
      from(r in Result, where: r.id == ^id and is_nil(r.seen_at))
      |> Repo.update_all(set: [seen_at: DateTime.utc_now()])

      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp put_player(id, attrs) do
    Repo.insert!(%Player{user_id: id}, on_conflict: :nothing)
    Repo.get!(Player, id) |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  @doc "The raw League tab contract; reads never place a player."
  def show(user, now \\ DateTime.utc_now()) do
    base = %{
      status: "off",
      league: nil,
      week: nil,
      room: nil,
      me: nil,
      last_week: nil,
      pending_result: nil,
      friends: [],
      ribbons: %{current: nil, past: []},
      intro_seen: false,
      classic: false
    }

    cond do
      not enabled?(now) -> base
      user.guest -> %{base | status: "guest", week: week_map(now)}
      true -> show_player(user, now, base)
    end
  end

  defp show_player(user, now, base) do
    player = player(user.id)
    {_, closes} = week(now)
    member = if not player.hidden, do: membership(user.id, closes)
    room = member && Repo.get!(Room, member.room_id)
    ranked = if room, do: standings(room.id), else: []
    friends = if player.hidden, do: [], else: friends(user.id, closes)
    users = Auth.get_users_map(Enum.uniq([user.id | Enum.map(ranked ++ friends, & &1.user_id)]))

    history =
      Repo.all(from r in Result, where: r.user_id == ^user.id, order_by: [asc: r.week_closes_at])

    last = List.last(history)
    pending = Enum.find(history, &is_nil(&1.seen_at))
    me = Enum.find(ranked, &(&1.user_id == user.id))
    {promote, demote} = if room, do: bands(room.league, length(ranked)), else: {0, 0}
    running = if room, do: {closes, room.league}

    %{
      base
      | status:
          cond do
            player.hidden -> "opted_out"
            member -> "placed"
            true -> "not_placed"
          end,
        league: player.league,
        week: week_map(now),
        intro_seen: player.intro_seen,
        classic: users[user.id].pin == "classic",
        room:
          if(room,
            do: %{
              size: length(ranked),
              promote: promote,
              demote: demote,
              standings:
                Enum.map(ranked, fn m ->
                  Map.merge(identity(users[m.user_id]), %{
                    place: m.place,
                    points: m.points,
                    me: m.user_id == user.id
                  })
                end)
            }
          ),
        me: if(me, do: Map.take(me, [:place, :points])),
        last_week:
          if(last,
            do: %{
              league: last.old_league,
              place: last.place,
              room_size: last.room_size,
              points: last.points
            }
          ),
        pending_result: result_json(pending, history, now),
        friends:
          Enum.map(friends, fn f ->
            identity(users[f.user_id])
            |> Map.delete(:pin)
            |> Map.merge(Map.take(f, [:league, :place]))
          end),
        ribbons: Ribbons.list(history, now, running)
    }
  end

  defp week_map(now) do
    {starts, closes} = week(now)
    %{starts_at: starts, closes_at: closes}
  end

  defp identity(user),
    do: %{
      user_id: user.id,
      username: User.public_name(user),
      avatar: %{url: user.avatar_url},
      level: user.level,
      prestige: user.prestige,
      pin: user.pin
    }

  defp result_json(nil, _history, _now), do: nil

  defp result_json(result, history, now) do
    # Outcomes stay frozen; star eligibility reflects every close elapsed today.
    current = Ribbons.ribbon(history, result.ribbon["month"], now)

    ribbon =
      Map.put(
        result.ribbon,
        "star_possible",
        current.star_possible
      )

    result
    |> Map.take([
      :id,
      :week_starts_at,
      :week_closes_at,
      :old_league,
      :new_league,
      :move,
      :place,
      :points,
      :room_size
    ])
    |> Map.put(:ribbon, ribbon)
  end

  defp friends(user_id, closes) do
    friend_rooms =
      from m in Membership,
        join: f in Friendship,
        on: f.friend_id == m.user_id and f.user_id == ^user_id,
        where: m.closes_at == ^closes,
        select: m.room_id

    ranked =
      from m in Membership,
        join: r in Room,
        on: r.id == m.room_id,
        where: m.closes_at == ^closes and m.room_id in subquery(friend_rooms),
        select: %{
          user_id: m.user_id,
          league: r.league,
          place:
            over(row_number(),
              partition_by: m.room_id,
              order_by: [desc: m.points, asc: m.points_at, asc: m.user_id]
            )
        }

    Repo.all(
      from m in subquery(ranked),
        as: :friend,
        join: f in Friendship,
        on: f.user_id == ^user_id and f.friend_id == m.user_id,
        join: reverse in Friendship,
        on: reverse.user_id == m.user_id and reverse.friend_id == ^user_id,
        left_join: p in Player,
        on: p.user_id == m.user_id,
        where: is_nil(p.user_id) or not p.hidden,
        where:
          not exists(
            from b in Block,
              where:
                (b.user_id == ^user_id and b.blocked_id == parent_as(:friend).user_id) or
                  (b.blocked_id == ^user_id and b.user_id == parent_as(:friend).user_id)
          ),
        select: m
    )
    |> Enum.sort_by(
      &{-Enum.find_index(@leagues, fn league -> league == &1.league end), &1.place, &1.user_id}
    )
  end

  defp membership(user_id, closes),
    do: Repo.get_by(Membership, user_id: user_id, closes_at: closes)

  defp closed?(closes),
    do: Repo.exists?(from w in "league_weeks", where: w.closes_at == type(^closes, :utc_datetime))

  defp result?(user_id, closes),
    do:
      Repo.exists?(from r in Result, where: r.user_id == ^user_id and r.week_closes_at == ^closes)
end
