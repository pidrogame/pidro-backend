defmodule PidroServer.Stats.BetaReport do
  @moduledoc """
  The beta report behind `/admin/beta` (PID-311): which rules people play,
  whether the two-minute reconnect promise holds, the pace of timed turns,
  and who comes back.

  Beta players are the users who have played at least one game on this
  server. Every count is a map of `:accounts`, `:guests` (the user's guest
  flag) and `:all`; `:all` also counts players whose account has since been
  deleted. A game counts once in each column it belongs to, so a table with
  a guest and an account counts under both.

  Finished games come from `game_stats`. Games that started, ended early, and
  the seats a computer started in come from `game_archives`, which keep 30
  days. Ids, dates and counts only: no emails, names, hands or free text.
  """

  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.GameArchive.Archive
  alias PidroServer.Repo
  alias PidroServer.Stats.{AbandonmentEvent, GameStats, SeatEvent}

  @rule_sets ~w(finnish louisiana)
  @zero %{accounts: 0, guests: 0, all: 0}

  @doc "Builds the report for games and events between `from` and `to`, both inclusive (UTC days)."
  @spec build(Date.t(), Date.t(), Date.t()) :: map()
  def build(%Date{} = from, %Date{} = to, today \\ Date.utc_today()) do
    starts = DateTime.new!(from, ~T[00:00:00])
    ends = DateTime.new!(Date.add(to, 1), ~T[00:00:00])
    {naive_starts, naive_ends} = {DateTime.to_naive(starts), DateTime.to_naive(ends)}

    finished =
      Repo.all(
        from gs in GameStats,
          where: gs.completed_at >= ^starts and gs.completed_at < ^ends,
          select: %{rule_set: gs.rule_set, user_ids: gs.player_ids}
      )

    started =
      Repo.all(
        from a in Archive,
          where: a.started_at >= ^starts and a.started_at < ^ends,
          select: %{
            status: a.status,
            user_ids: a.user_ids,
            participants: a.participants,
            rule_set: fragment("?->'state'->>'variant'", a.last_snapshot)
          }
      )

    seat_events =
      Repo.all(
        from e in SeatEvent,
          where: e.inserted_at >= ^naive_starts and e.inserted_at < ^naive_ends,
          select: {e.user_id, e.kind, e.elapsed_ms}
      )

    takeovers =
      Repo.all(
        from ae in AbandonmentEvent,
          where: ae.inserted_at >= ^naive_starts and ae.inserted_at < ^naive_ends,
          select: ae.user_id
      )

    days = play_days()
    cohort = for {id, [first | _] = played} <- days, in_range?(first, from, to), do: {id, played}
    players = Enum.uniq(Enum.flat_map(finished ++ started, & &1.user_ids))

    groups =
      (players ++
         Enum.map(seat_events, &elem(&1, 0)) ++ takeovers ++ Enum.map(cohort, &elem(&1, 0)))
      |> groups()

    events = fn kinds -> for {id, kind, _} <- seat_events, kind in kinds, do: id end

    %{
      from: from,
      to: to,
      players: tally(Enum.filter(players, &human?/1), groups),
      rule_sets:
        for rule_set <- @rule_sets do
          %{
            rule_set: rule_set,
            finished: tally_games(Enum.filter(finished, &(&1.rule_set == rule_set)), groups),
            closed: tally_games(ended(started, rule_set, "closed"), groups),
            interrupted: tally_games(ended(started, rule_set, "interrupted"), groups)
          }
        end,
      games_started: tally_games(started, groups),
      computer_seats: tally_games(started, groups, &computer_seats/1),
      takeovers: tally(takeovers, groups),
      drops: tally(events.(["drop"]), groups),
      returns: tally(events.(["return"]), groups),
      timed_turns: tally(events.(["turn", "timeout"]), groups),
      timeouts: tally(events.(["timeout"]), groups),
      median_turn_ms: median_turn_ms(seat_events, groups),
      new_players: tally(Enum.map(cohort, &elem(&1, 0)), groups),
      day2: back_on(cohort, 2, today, groups),
      day7: back_on(cohort, 7, today, groups)
    }
  end

  @doc "CSV of `classic_user_id` and the first day the player played here, for players who have."
  @spec classic_csv() :: String.t()
  def classic_csv do
    days = play_days()

    rows =
      from(u in User, where: not is_nil(u.classic_user_id), select: {u.id, u.classic_user_id})
      |> Repo.all()
      |> Enum.flat_map(fn {id, classic_user_id} ->
        case days do
          %{^id => [first | _]} -> [{classic_user_id, first}]
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {classic_user_id, first} ->
        {Date.to_iso8601(first), classic_user_id}
      end)

    ["classic_user_id,first_played_on\n" | Enum.map(rows, fn {id, day} -> "#{id},#{day}\n" end)]
    |> IO.iodata_to_binary()
  end

  @doc "Filename for `classic_csv/0`."
  @spec classic_csv_filename() :: String.t()
  def classic_csv_filename, do: "pidro-classic-first-played-#{Date.utc_today()}.csv"

  # Every UTC day each player finished or started a game: %{user_id => [Date]},
  # sorted. Days with only a started game go when the archive does (30 days).
  defp play_days do
    finished =
      from gs in GameStats,
        distinct: true,
        select: {fragment("unnest(?)::text", gs.player_ids), fragment("?::date", gs.completed_at)}

    started =
      from a in Archive,
        distinct: true,
        select: {fragment("unnest(?)", a.user_ids), fragment("?::date", a.started_at)}

    (Repo.all(finished) ++ Repo.all(started))
    |> Enum.filter(fn {id, _day} -> human?(id) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, days} -> {id, days |> Enum.uniq() |> Enum.sort(Date)} end)
  end

  defp groups(ids) do
    ids = ids |> Enum.filter(&human?/1) |> Enum.uniq()

    from(u in User, where: u.id in ^ids, select: {u.id, u.guest})
    |> Repo.all()
    |> Map.new(fn {id, guest} -> {id, if(guest, do: :guests, else: :accounts)} end)
  end

  # Bots and test fixtures carry ids that are not UUIDs; players always do.
  defp human?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  defp tally(ids, groups) do
    Enum.reduce(ids, @zero, fn id, acc -> bump(acc, [:all | List.wrap(groups[id])], 1) end)
  end

  defp tally_games(games, groups, weight \\ fn _game -> 1 end) do
    Enum.reduce(games, @zero, fn game, acc ->
      columns = game.user_ids |> Enum.map(&groups[&1]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      bump(acc, [:all | columns], weight.(game))
    end)
  end

  defp bump(acc, columns, n),
    do: Enum.reduce(columns, acc, &Map.update!(&2, &1, fn c -> c + n end))

  defp ended(started, rule_set, status),
    do: Enum.filter(started, &(&1.rule_set == rule_set and &1.status == status))

  defp computer_seats(%{participants: participants}),
    do: Enum.count(participants, fn {_position, seat} -> seat["occupant_type"] == "bot" end)

  defp median_turn_ms(seat_events, groups) do
    timed = for {id, kind, ms} <- seat_events, kind in ["turn", "timeout"], do: {groups[id], ms}

    Map.new([:accounts, :guests, :all], fn column ->
      {column, median(for {group, ms} <- timed, column in [:all, group], do: ms)}
    end)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    half = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, half),
      else: div(Enum.at(sorted, half - 1) + Enum.at(sorted, half), 2)
  end

  # Day 1 is the first day played. A player is due for day n once that day is
  # over, or as soon as they are back on it.
  defp back_on(cohort, n, today, groups) do
    {returned, due} =
      Enum.reduce(cohort, {[], []}, fn {id, played}, {returned, due} ->
        day = Date.add(hd(played), n - 1)
        back? = day in played

        cond do
          back? -> {[id | returned], [id | due]}
          Date.compare(day, today) == :lt -> {returned, [id | due]}
          true -> {returned, due}
        end
      end)

    %{returned: tally(returned, groups), due: tally(due, groups)}
  end

  defp in_range?(day, from, to),
    do: Date.compare(day, from) != :lt and Date.compare(day, to) != :gt
end
