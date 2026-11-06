defmodule PidroServer.Stats do
  @moduledoc """
  Context for game statistics and analytics.
  Handles saving game results and aggregating user stats.
  """

  require Logger
  import Ecto.Query, warn: false
  alias PidroServer.Profiles
  alias PidroServer.Repo
  alias PidroServer.Stats.{AbandonmentEvent, ConnectionGame, GameStats, SeatEvent}

  @connection_thresholds %{
    minimum_seconds: 600,
    good_ms: 150,
    good_drops: 1,
    fair_ms: 400,
    fair_drops: 4
  }

  @doc "Connection grade from measured play time, median RTT and drops; boundaries are exclusive."
  def connection_grade(%{duration_seconds: seconds, median_ms: median, drops: drops}) do
    limits = @connection_thresholds

    cond do
      seconds < limits.minimum_seconds or is_nil(median) -> :insufficient
      median < limits.good_ms and drops * 3600 / seconds < limits.good_drops -> :good
      median < limits.fair_ms and drops * 3600 / seconds < limits.fair_drops -> :fair
      true -> :poor
    end
  end

  @doc "Persists one final aggregate per player/game, off the table's process."
  def record_connection_game(attrs) do
    attrs = Map.merge(attrs, connection_percentiles(attrs.rtt_histogram))
    changeset = ConnectionGame.changeset(%ConnectionGame{}, attrs)

    Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
      try do
        case Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:user_id, :game_instance_id]
             ) do
          {:ok, _} -> :ok
          {:error, _} -> Logger.warning("Connection game aggregate rejected")
        end
      catch
        failure, _ -> Logger.warning("Connection game aggregate not recorded: #{failure}")
      end
    end)

    :ok
  end

  @doc "The player's recent per-game connection aggregates, newest first."
  def connection_games(user_id, days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.all(
      from c in ConnectionGame,
        where: c.user_id == ^user_id and c.inserted_at >= ^cutoff,
        order_by: [desc: c.inserted_at, desc: c.id]
    )
  end

  @doc "Combines sample frequencies and network durations; never averages per-game percentiles."
  def summarize_connections(rows) do
    totals =
      Map.new(
        [:duration_seconds, :disconnected_seconds, :drops, :checks_sent, :unanswered_checks],
        fn key ->
          {key, Enum.reduce(rows, 0, &(Map.get(&1, key, 0) + &2))}
        end
      )

    histogram = merge_connection_counts(rows, :rtt_histogram)
    networks = merge_connection_counts(rows, :network_ms)
    {network, _} = Enum.max_by(networks, fn {_network, ms} -> ms end, fn -> {"unknown", 0} end)
    totals = Map.merge(totals, connection_percentiles(histogram))
    measured = Enum.filter(rows, &(map_size(Map.get(&1, :rtt_histogram, %{})) > 0))
    measured_seconds = Enum.sum(Enum.map(measured, & &1.duration_seconds))
    measured_drops = Enum.sum(Enum.map(measured, & &1.drops))

    Map.merge(totals, %{
      grade:
        connection_grade(%{totals | duration_seconds: measured_seconds, drops: measured_drops}),
      measured_seconds: measured_seconds,
      unknown_seconds: totals.duration_seconds - measured_seconds,
      network: network,
      drops_per_hour:
        if(measured_seconds > 0,
          do: measured_drops * 3600 / measured_seconds,
          else: 0
        ),
      app_version: Map.get(List.first(rows) || %{}, :app_version),
      platform: Map.get(List.first(rows) || %{}, :platform)
    })
  end

  @doc "Share of recorded play time graded poor, by platform/version, with unknown time separate."
  def connection_analytics(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.all(from c in ConnectionGame, where: c.inserted_at >= ^cutoff)
    |> Enum.group_by(&{&1.user_id, &1.platform, &1.app_version})
    |> Enum.map(fn {{_user, platform, version}, rows} ->
      Map.merge(summarize_connections(rows), %{platform: platform, app_version: version})
    end)
    |> Enum.group_by(&{&1.platform, &1.app_version})
    |> Enum.map(fn {{platform, version}, players} ->
      total = Enum.sum(Enum.map(players, & &1.duration_seconds))
      poor = Enum.sum(for p <- players, p.grade == :poor, do: p.measured_seconds)

      unknown =
        Enum.sum(
          for p <- players,
              do: if(p.grade == :insufficient, do: p.duration_seconds, else: p.unknown_seconds)
        )

      %{
        platform: platform,
        app_version: version,
        duration_seconds: total,
        poor_percent: if(total > 0, do: poor * 100 / total, else: 0),
        unknown_percent: if(total > 0, do: unknown * 100 / total, else: 0)
      }
    end)
    |> Enum.sort_by(&{&1.platform, &1.app_version})
  end

  defp merge_connection_counts(rows, key) do
    Enum.reduce(rows, %{}, fn row, counts ->
      Map.merge(counts, Map.get(row, key, %{}), fn _key, left, right -> left + right end)
    end)
  end

  defp connection_percentiles(histogram) when map_size(histogram) == 0,
    do: %{median_ms: nil, p95_ms: nil}

  defp connection_percentiles(histogram) do
    sorted =
      histogram |> Enum.map(fn {ms, count} -> {String.to_integer(ms), count} end) |> Enum.sort()

    count = Enum.sum(Map.values(histogram))

    %{
      median_ms:
        (connection_rank(sorted, div(count + 1, 2)) + connection_rank(sorted, div(count, 2) + 1)) /
          2,
      p95_ms: connection_rank(sorted, ceil(count * 0.95)) / 1
    }
  end

  defp connection_rank([{ms, count} | _], rank) when rank <= count, do: ms
  defp connection_rank([{_ms, count} | rest], rank), do: connection_rank(rest, rank - count)

  @doc """
  Saves game result after completion.

  ## Examples

      iex> save_game_result(%{room_code: "ABC123", winner: :north_south, ...})
      {:ok, %GameStats{}}

      iex> save_game_result(%{})
      {:error, %Ecto.Changeset{}}
  """
  def save_game_result(attrs) do
    %GameStats{}
    |> GameStats.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets stats for a specific user.

  Returns aggregated statistics including:
  - Total games played
  - Wins/losses
  - Average bid amount
  - Total duration played

  ## Examples

      iex> get_user_stats(user_id)
      %{
        games_played: 42,
        wins: 25,
        losses: 17,
        win_rate: 0.595,
        total_duration_seconds: 12600,
        average_bid: 10.5
      }
  """
  def get_user_stats(user_id) do
    games_query =
      from gs in GameStats,
        where: ^user_id in gs.player_ids,
        select: gs

    games = Repo.all(games_query)
    games_abandoned = count_abandonments(user_id)
    last_abandoned_at = last_abandoned_at(user_id)

    total_games = length(games)
    wins = count_user_wins(games, user_id)
    losses = total_games - wins
    total_duration = Enum.reduce(games, 0, fn g, acc -> acc + (g.duration_seconds || 0) end)
    total_bids = Enum.reduce(games, 0, fn g, acc -> acc + (g.bid_amount || 0) end)
    avg_bid = if total_games > 0, do: total_bids / total_games, else: 0.0

    %{
      games_played: total_games,
      wins: wins,
      losses: losses,
      win_rate: if(total_games > 0, do: wins / total_games, else: 0.0),
      total_duration_seconds: total_duration,
      average_bid: avg_bid,
      games_abandoned: games_abandoned,
      abandonment_rate: if(total_games > 0, do: games_abandoned / total_games, else: 0.0),
      last_abandoned_at: last_abandoned_at
    }
  end

  @doc """
  Gets compact game stats for a set of users.

  This is intended for admin lists where loading each user one by one would
  create unnecessary database chatter.
  """
  def get_user_stats_map(user_ids) when is_list(user_ids) do
    user_ids = Enum.uniq(user_ids)

    if Enum.empty?(user_ids) do
      %{}
    else
      games =
        from(gs in GameStats,
          where: fragment("? && ?", gs.player_ids, type(^user_ids, {:array, :binary_id}))
        )
        |> Repo.all()

      abandonments = abandonment_summary(user_ids)

      games_by_user =
        Enum.reduce(games, %{}, fn game, acc ->
          game_user_ids =
            game
            |> Map.get(:player_ids, [])
            |> Enum.filter(&(&1 in user_ids))

          Enum.reduce(game_user_ids, acc, fn user_id, user_acc ->
            Map.update(user_acc, user_id, [game], &[game | &1])
          end)
        end)

      Map.new(user_ids, fn user_id ->
        user_games = Map.get(games_by_user, user_id, [])
        games_played = length(user_games)
        wins = count_user_wins(user_games, user_id)
        games_abandoned = get_in(abandonments, [user_id, :count]) || 0
        last_abandoned_at = get_in(abandonments, [user_id, :last_abandoned_at])

        {user_id,
         %{
           games_played: games_played,
           wins: wins,
           losses: games_played - wins,
           win_rate: if(games_played > 0, do: wins / games_played, else: 0.0),
           games_abandoned: games_abandoned,
           last_abandoned_at: last_abandoned_at
         }}
      end)
    end
  end

  def get_user_stats_map(_user_ids), do: %{}

  @doc """
  Gets all game stats for a room code.
  """
  def get_game_by_room_code(room_code) do
    Repo.get_by(GameStats, room_code: room_code)
  end

  @doc """
  Lists recent games, optionally filtered by player.
  """
  def list_recent_games(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    player_id = Keyword.get(opts, :player_id)

    query =
      from gs in GameStats,
        order_by: [desc: gs.completed_at],
        limit: ^limit

    query =
      if player_id do
        from gs in query,
          where: ^player_id in gs.player_ids
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Lists recent abandonment events for a player.
  """
  def list_user_abandonments(user_id, limit \\ 20) do
    from(ae in AbandonmentEvent,
      where: ae.user_id == ^user_id,
      order_by: [desc: ae.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Returns a player's stored result map for a completed game.
  """
  def player_result_for(%GameStats{} = game, user_id) do
    game
    |> get_player_result(user_id)
    |> normalize_player_result()
  end

  @doc """
  Gets leaderboard stats.
  Returns top players by win count.
  """
  def get_leaderboard(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # This is a simplified version - in production you'd want to
    # maintain a separate leaderboard table or use more efficient queries
    query =
      from gs in GameStats,
        select: gs

    games = Repo.all(query)

    # Group by player and count wins
    player_stats =
      games
      |> Enum.flat_map(fn game ->
        Enum.map(game.player_ids || [], fn player_id ->
          {player_id, game}
        end)
      end)
      |> Enum.group_by(fn {player_id, _game} -> player_id end)
      |> Enum.map(fn {player_id, player_games} ->
        games_list = Enum.map(player_games, fn {_id, game} -> game end)
        wins = count_user_wins(games_list, player_id)

        %{
          player_id: player_id,
          games_played: length(games_list),
          wins: wins,
          win_rate: if(length(games_list) > 0, do: wins / length(games_list), else: 0.0)
        }
      end)
      |> Enum.sort_by(& &1.wins, :desc)
      |> Enum.take(limit)

    player_stats
  end

  @doc """
  Builds per-player results from seat data at game completion.

  Iterates through all seats and classifies each player's participation:

    * Connected human → `:played`
    * Bot with `reserved_for` set (abandoned human) → `:abandoned`
    * Bot without `reserved_for` (pure bot) → skipped
    * Human who joined as substitute → `:substitute` (Phase 8)

  Returns a map of `%{user_id => %{participation, result, team, position}}`.
  """
  @spec build_player_results(map(), atom(), [AbandonmentEvent.t() | map()]) :: map()
  def build_player_results(seats, winner, abandonment_events \\ [])

  def build_player_results(seats, winner, abandonment_events)
      when is_map(seats) and is_list(abandonment_events) do
    seats
    |> Enum.reduce(%{}, fn {position, seat}, acc ->
      case classify_seat(seat) do
        {:record, user_id, participation} ->
          Map.put(acc, user_id, build_result(participation, position, winner))

        :skip ->
          acc
      end
    end)
    |> merge_abandonment_events(abandonment_events, winner)
  end

  def build_player_results(_seats, _winner, _abandonment_events), do: %{}

  @doc """
  Builds per-player bidding facts from the live `GameState.events` log + the
  room's `seats` at game completion (PID-51).

  The `events` list is appended-only across the whole game, so it holds one
  `{:bidding_complete, position, amount}` per hand (the winning seat + amount).
  This pure folder reads ONLY `:bidding_complete` events:

    * **attempts** — every human-resolved seat participates in every hand's
      bidding, so each such user's `attempts` == the number of `:bidding_complete`
      events (the hand count). A player who left mid-game is still attributed to
      their seat's resolved id for the whole game (same FINAL-seat-state
      attribution `build_player_results/3` uses).
    * **wins / won_bid_sum** — for each `:bidding_complete{position, amount}`,
      resolve `position → user_id` via `seats` (reusing `classify_seat/1`); if it
      resolves to a human, increment that user's `wins` by 1 and `won_bid_sum` by
      `amount`. Positions resolving to a bot (no user_id) contribute nothing.

  Returns `%{user_id => %{"attempts" => n, "wins" => m, "won_bid_sum" => s}}`
  (string keys, mirroring the JSONB round-trip shape). Users who participated but
  never won a bid still get a row (`wins: 0, won_bid_sum: 0`).

  Tolerant base case: `events` not a list, `seats` not a map, or no
  `:bidding_complete` present → `%{}` (legacy / bot-only / missing — contributes
  zero on accumulate and rebuild).
  """
  @spec build_player_bidding(list() | nil, map()) :: map()
  def build_player_bidding(events, seats) when is_list(events) and is_map(seats) do
    completions =
      Enum.filter(events, fn
        {:bidding_complete, _position, _amount} -> true
        _ -> false
      end)

    hand_count = length(completions)

    if hand_count == 0 do
      %{}
    else
      # Resolve every human-occupied seat to its user_id and seed an empty
      # accumulator (so participants who never won a bid still record attempts).
      position_to_user =
        Enum.reduce(seats, %{}, fn {position, seat}, acc ->
          case classify_seat(seat) do
            {:record, user_id, _participation} -> Map.put(acc, position, user_id)
            :skip -> acc
          end
        end)

      base =
        Map.new(Map.values(position_to_user), fn user_id ->
          {user_id, %{"attempts" => hand_count, "wins" => 0, "won_bid_sum" => 0}}
        end)

      Enum.reduce(completions, base, fn {:bidding_complete, position, amount}, acc ->
        case Map.get(position_to_user, position) do
          nil ->
            acc

          user_id ->
            Map.update!(acc, user_id, fn facts ->
              facts
              |> Map.update!("wins", &(&1 + 1))
              |> Map.update!("won_bid_sum", &(&1 + win_amount(amount)))
            end)
        end
      end)
    end
  end

  def build_player_bidding(_events, _seats), do: %{}

  defp win_amount(amount) when is_integer(amount), do: amount
  defp win_amount(_amount), do: 0

  # Pulls the GameState.events list when present, tolerating a nil game_state.
  defp events_of(%{events: events}) when is_list(events), do: events
  defp events_of(_game_state), do: []

  @doc """
  Records a player abandonment.

  Called when a player leaves deliberately or is still absent at game over.
  A substitute covering during the game does not count as abandonment.

  This data will be used for matchmaking penalties and profile badges
  in a future phase.

  ## Parameters

    * `user_id` - The ID of the player who abandoned the game
    * `room_code` - The room code where the abandonment occurred
    * `position` - The seat position that was abandoned
  """
  @spec record_abandonment(String.t(), String.t(), atom()) :: :ok
  def record_abandonment(user_id, room_code, position) do
    attrs = %{
      user_id: user_id,
      room_code: room_code,
      position: Atom.to_string(position)
    }

    %AbandonmentEvent{}
    |> AbandonmentEvent.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :room_code]
    )

    Logger.info("Abandonment recorded: user=#{user_id} room=#{room_code} position=#{position}")

    :ok
  end

  @doc """
  Records a drop, a return within grace, a timed turn or a turn timeout for
  the beta report. See `PidroServer.Stats.SeatEvent` for the kinds.

  Best-effort and off the caller, which is the RoomManager on a turn: a slow
  or failed write must never hold up or crash the tables.
  """
  @spec record_seat_event(String.t(), String.t(), String.t(), non_neg_integer() | nil) :: :ok
  def record_seat_event(user_id, room_code, kind, elapsed_ms \\ nil, client \\ %{}) do
    changeset =
      SeatEvent.changeset(%SeatEvent{}, %{
        user_id: user_id,
        room_code: room_code,
        kind: kind,
        elapsed_ms: elapsed_ms,
        app_version: Map.get(client, :app_version),
        platform: Map.get(client, :platform),
        reason: Map.get(client, :reason),
        network: Map.get(client, :network)
      })

    Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
      try do
        Repo.insert(changeset)
      catch
        failure, _reason -> Logger.info("Seat event #{kind} not recorded: #{failure}")
      end
    end)

    :ok
  end

  @doc "The player's fifty most recent connection events, newest first."
  @spec connection_timeline(String.t()) :: [struct()]
  def connection_timeline(user_id) do
    Repo.all(
      from e in SeatEvent,
        where: e.user_id == ^user_id and e.kind != "turn",
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 50
    )
  end

  @doc "Connection events over the last seven days and the last reported app build."
  @spec connection_summary(String.t()) :: map()
  def connection_summary(user_id) do
    cutoff = DateTime.utc_now() |> DateTime.add(-7, :day)

    counts =
      Repo.all(
        from e in SeatEvent,
          where: e.user_id == ^user_id and e.inserted_at >= ^cutoff,
          group_by: e.kind,
          select: {e.kind, count(e.id)}
      )
      |> Map.new()

    latest =
      Repo.one(
        from e in SeatEvent,
          where: e.user_id == ^user_id and not is_nil(e.app_version),
          order_by: [desc: e.inserted_at],
          limit: 1,
          select: %{app_version: e.app_version, platform: e.platform}
      )

    Map.merge(
      %{drops: Map.get(counts, "drop", 0), auto_plays: Map.get(counts, "timeout", 0)},
      latest || %{app_version: nil, platform: nil}
    )
  end

  @doc """
  Persists the final game result exactly once per finished game.

  A game is identified by `opts[:game_instance_id]`, the engine's id for the
  game process. A room can host several games (rematch) and a room code is
  reused once its room closes, so the room code does not identify a game.
  Callers that pass no instance id keep the older room-code check.

  `room.game_started_at`, when set, is the start of this game: it bounds the
  duration and the abandonment events that count against this result.
  `:completed_at` permits historical replay; live callers default to now.

  On a successful first save, returns `{:ok, summaries}` where `summaries` is the
  ephemeral `%{user_id => post_game_summary_map}` from
  `Profiles.apply_completed_game/4` (PID-52). On the idempotent short-circuit
  (already saved) or a rolled-back transaction, returns `:ok` — no summary is
  ever surfaced for a re-fire or a rollback.
  """
  @spec save_completed_game(map(), atom(), map(), map() | nil, keyword()) ::
          {:ok, %{optional(Ecto.UUID.t()) => map()}} | :ok
  def save_completed_game(
        %{code: room_code} = room,
        winner,
        scores,
        game_state \\ nil,
        opts \\ []
      ) do
    game_instance_id = Keyword.get(opts, :game_instance_id)
    completed_at = Keyword.get_lazy(opts, :completed_at, &DateTime.utc_now/0)
    game_started_at = Map.get(room, :game_started_at) || room.created_at

    if game_saved?(room_code, game_instance_id) do
      :ok
    else
      bid_info = extract_bid_info(game_state)
      duration_seconds = max(1, DateTime.diff(completed_at, game_started_at, :second))
      abandonment_events = list_abandonments_for_room(room_code, game_started_at)
      player_results = build_player_results(room.seats, winner, abandonment_events)
      player_results = reject_bot_results(player_results)
      player_bidding = build_player_bidding(events_of(game_state), room.seats)

      stats_attrs = %{
        room_code: room_code,
        rule_set: get_in(room, [Access.key(:config, %{}), Access.key(:rule_set, :finnish)]),
        game_instance_id: game_instance_id,
        winner: winner,
        final_scores: scores,
        bid_amount: bid_info.bid_amount,
        bid_team: bid_info.bid_team,
        duration_seconds: duration_seconds,
        completed_at: completed_at,
        player_ids: Map.keys(player_results),
        player_results: player_results,
        player_bidding: player_bidding
      }

      result =
        Repo.transaction(fn ->
          case save_game_result(stats_attrs) do
            {:ok, stats} ->
              # PID-52: apply_completed_game returns the per-user ephemeral
              # post-game summaries; carry them out of the transaction so the
              # caller can push them per-player after the commit.
              {:ok, summaries} =
                Profiles.apply_completed_game(player_results, winner, scores, player_bidding,
                  rule_set: stats_attrs.rule_set,
                  game: stats
                )

              summaries

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, summaries} ->
          Logger.info("Saved game stats for room #{room_code}")
          {:ok, summaries}

        {:error, changeset} ->
          Logger.error("Failed to save game stats for room #{room_code}: #{inspect(changeset)}")
          :ok
      end
    end
  end

  @doc """
  Lists abandonment events for a completed room.
  """
  @spec list_abandonments_for_room(String.t(), DateTime.t() | nil) :: [AbandonmentEvent.t()]
  def list_abandonments_for_room(room_code, since \\ nil) do
    from(ae in AbandonmentEvent,
      where: ae.room_code == ^room_code,
      order_by: [asc: ae.inserted_at]
    )
    |> abandoned_since(since)
    |> Repo.all()
  end

  # `inserted_at` has second precision, so compare against the truncated start.
  defp abandoned_since(query, nil), do: query

  defp abandoned_since(query, %DateTime{} = since) do
    since = since |> DateTime.truncate(:second) |> DateTime.to_naive()
    from(ae in query, where: ae.inserted_at >= ^since)
  end

  defp game_saved?(_room_code, game_instance_id) when is_binary(game_instance_id) do
    Repo.exists?(from(gs in GameStats, where: gs.game_instance_id == ^game_instance_id))
  end

  defp game_saved?(room_code, nil) do
    Repo.exists?(from(gs in GameStats, where: gs.room_code == ^room_code))
  end

  # Private helpers

  defp count_abandonments(user_id) do
    from(ae in AbandonmentEvent, where: ae.user_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  defp abandonment_summary(user_ids) do
    from(ae in AbandonmentEvent,
      where: ae.user_id in ^user_ids,
      group_by: ae.user_id,
      select: {ae.user_id, count(ae.id), max(ae.inserted_at)}
    )
    |> Repo.all()
    |> Map.new(fn {user_id, count, last_abandoned_at} ->
      {user_id, %{count: count, last_abandoned_at: to_utc_datetime(last_abandoned_at)}}
    end)
  end

  defp last_abandoned_at(user_id) do
    from(ae in AbandonmentEvent, where: ae.user_id == ^user_id, select: max(ae.inserted_at))
    |> Repo.one()
    |> to_utc_datetime()
  end

  defp classify_seat(%{
         occupant_type: :human,
         status: :connected,
         substitute: true,
         user_id: user_id
       })
       when not is_nil(user_id) do
    {:record, user_id, :substitute}
  end

  defp classify_seat(%{occupant_type: :human, status: :connected, user_id: user_id})
       when not is_nil(user_id) do
    {:record, user_id, :played}
  end

  defp classify_seat(%{occupant_type: :bot, reserved_for: reserved_for})
       when not is_nil(reserved_for) do
    # Abandoned human — bot is playing but the original human can still reclaim
    {:record, reserved_for, :abandoned}
  end

  defp classify_seat(_seat), do: :skip

  defp reject_bot_results(player_results) when is_map(player_results) do
    Map.reject(player_results, fn {user_id, _result} -> bot_user_id?(user_id) end)
  end

  defp reject_bot_results(_player_results), do: %{}

  defp bot_user_id?(user_id) when is_binary(user_id), do: String.starts_with?(user_id, "bot_")
  defp bot_user_id?(_user_id), do: false

  defp build_result(participation, position, winner) do
    team = team_for_position(position)
    result = if team == winner, do: :win, else: :loss

    %{
      participation: participation,
      result: result,
      team: team,
      position: position
    }
  end

  defp merge_abandonment_events(results, abandonment_events, winner) do
    Enum.reduce(abandonment_events, results, fn event, acc ->
      case normalize_abandonment_event(event) do
        {:ok, user_id, position} ->
          Map.put_new(acc, user_id, build_result(:abandoned, position, winner))

        :error ->
          acc
      end
    end)
  end

  defp normalize_abandonment_event(%AbandonmentEvent{user_id: user_id, position: position}) do
    normalize_abandonment_event(%{user_id: user_id, position: position})
  end

  defp normalize_abandonment_event(%{user_id: user_id, position: position})
       when is_binary(user_id) do
    case normalize_position(position) do
      {:ok, position_atom} -> {:ok, user_id, position_atom}
      :error -> :error
    end
  end

  defp normalize_abandonment_event(_event), do: :error

  defp normalize_position(position) when position in [:north, :east, :south, :west],
    do: {:ok, position}

  defp normalize_position("north"), do: {:ok, :north}
  defp normalize_position("east"), do: {:ok, :east}
  defp normalize_position("south"), do: {:ok, :south}
  defp normalize_position("west"), do: {:ok, :west}
  defp normalize_position(_position), do: :error

  defp team_for_position(position) when position in [:north, :south], do: :north_south
  defp team_for_position(position) when position in [:east, :west], do: :east_west

  defp extract_bid_info(%{highest_bid: {position, amount}})
       when position in [:north, :east, :south, :west] and is_integer(amount) do
    %{bid_amount: amount, bid_team: team_for_position(position)}
  end

  defp extract_bid_info(%{highest_bid: %{position: position, amount: amount}})
       when is_integer(amount) do
    case normalize_position(position) do
      {:ok, position_atom} ->
        %{bid_amount: amount, bid_team: team_for_position(position_atom)}

      :error ->
        %{bid_amount: nil, bid_team: nil}
    end
  end

  defp extract_bid_info(_game_state), do: %{bid_amount: nil, bid_team: nil}

  defp to_utc_datetime(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp to_utc_datetime(%DateTime{} = datetime), do: datetime
  defp to_utc_datetime(nil), do: nil

  defp count_user_wins(games, user_id) do
    Enum.count(games, fn game ->
      case get_player_result(game, user_id) do
        %{result: :win} ->
          true

        _ ->
          winner = game.winner
          player_position = get_player_position(game, user_id)

          case {winner, player_position} do
            {:north_south, pos} when pos in [:north, :south] -> true
            {:east_west, pos} when pos in [:east, :west] -> true
            {"north_south", pos} when pos in [:north, :south] -> true
            {"east_west", pos} when pos in [:east, :west] -> true
            _ -> false
          end
      end
    end)
  end

  defp get_player_result(%{player_results: player_results}, user_id)
       when is_map(player_results) do
    Map.get(player_results, user_id) || Map.get(player_results, to_string(user_id))
  end

  defp get_player_result(_game, _user_id), do: nil

  defp normalize_player_result(nil), do: nil

  defp normalize_player_result(result) when is_map(result) do
    %{
      participation: result[:participation] || result["participation"],
      result: result[:result] || result["result"],
      team: result[:team] || result["team"],
      position: result[:position] || result["position"]
    }
  end

  defp get_player_position(game, user_id) do
    player_ids = game.player_ids || []
    index = Enum.find_index(player_ids, &(&1 == user_id))

    case index do
      0 -> :north
      1 -> :east
      2 -> :south
      3 -> :west
      _ -> nil
    end
  end
end
