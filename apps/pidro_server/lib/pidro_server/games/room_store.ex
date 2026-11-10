defmodule PidroServer.Games.RoomStore do
  @moduledoc """
  The `live_rooms` table: one row per open room, so a deploy's new node can
  bring the room back.

  A row names the RoomManager that owns the room (`owner`, a boot id) and an
  `epoch` that every takeover bumps. Writes for a room, its game's
  checkpoints included, succeed only against the owner and epoch the writer
  holds, so two nodes never both advance a room. Owners heartbeat their rows;
  a released row (`owner` NULL) or one whose heartbeat is stale may be
  claimed by any node, and a node claims any row a player asks it for.

  The room is stored as `GameArchive.Serialization` JSON without its timers,
  processes and talk. Room JSON has user ids and names, so `decode/1` knows
  which fields are strings; everything else is an atom, a time or a number.

  Every function is a no-op while `:game_archive_enabled` is false, as it is
  under the SQL sandbox, and none raises: a failed write is reported to the
  caller, who keeps serving.
  """
  require Logger

  alias PidroServer.GameArchive.Serialization
  alias PidroServer.Games.Room.{Config, Seat}
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Repo

  # A heartbeat runs every 2 s; five missed ones mean the owner is gone.
  @stale "interval '10 seconds'"
  @timeout 500

  @strings ~w(id code host_id kicked_ids positions spectator_ids user_id reserved_for decision_id
    decision_player_id vacated_by bot_persona bot_personas name seat_holds seat_personas seat_password
    ready_player_ids app_version app_build platform reason network peers left bot_talk)
  @times ~w(created_at last_activity invite_live_until)
  @structs %{
    "Elixir.PidroServer.Games.RoomManager.Room" => Room,
    "Elixir.PidroServer.Games.Room.Config" => Config,
    "Elixir.PidroServer.Games.Room.Seat" => Seat
  }

  @type owner :: String.t()
  @type claimed :: %{epoch: pos_integer(), game_instance_id: String.t() | nil, room: map() | nil}

  @doc "Whether rooms persist; follows `:game_archive_enabled`."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:pidro_server, :game_archive_enabled, true)

  @doc "Claims a fresh code for a new room at epoch 1: `:taken` if any row has it."
  @spec insert(String.t(), owner()) :: :ok | :taken | :error
  def insert(code, owner) do
    run(:ok, fn ->
      case sql(
             "INSERT INTO live_rooms (code, owner, epoch, heartbeat_at, updated_at) " <>
               "VALUES ($1, $2, 1, now(), now()) ON CONFLICT DO NOTHING",
             [code, owner]
           ) do
        %{num_rows: 1} -> :ok
        %{num_rows: 0} -> :taken
      end
    end)
  end

  @doc "Whether this owner holds the room's row at epoch 1, as a fresh insert does."
  @spec inserted?(String.t(), owner()) :: boolean()
  def inserted?(code, owner) do
    run(false, fn ->
      %{rows: [[held?]]} =
        sql(
          "SELECT EXISTS (SELECT 1 FROM live_rooms WHERE code = $1 AND owner = $2 AND epoch = 1)",
          [code, owner]
        )

      held?
    end) == true
  end

  @doc "Saves the room's JSON; `:fenced` once another owner or epoch holds the row."
  @spec save(String.t(), owner(), pos_integer(), map()) :: :ok | :fenced | :error
  def save(code, owner, epoch, room) do
    run(:ok, fn ->
      case sql(
             "UPDATE live_rooms SET room = $4, updated_at = now() " <>
               "WHERE code = $1 AND owner = $2 AND epoch = $3",
             [code, owner, epoch, room]
           ) do
        %{num_rows: 1} -> :ok
        %{num_rows: 0} -> :fenced
      end
    end)
  end

  @doc "Deletes a closed room's row, if this owner and epoch still hold it."
  @spec delete(String.t(), owner(), pos_integer()) :: :ok | :error
  def delete(code, owner, epoch) do
    run(:ok, fn ->
      sql("DELETE FROM live_rooms WHERE code = $1 AND owner = $2 AND epoch = $3", [
        code,
        owner,
        epoch
      ])

      :ok
    end)
  end

  @doc """
  Keeps the rows of the rooms this owner serves fresh and returns the codes it
  still holds. A row it holds but no longer serves goes stale, so it is
  claimed and restored, or found closed, like any other.
  """
  @spec heartbeat(owner(), [String.t()]) :: {:ok, [String.t()]} | :skip | :error
  def heartbeat(owner, codes) do
    run(:skip, fn ->
      %{rows: rows} =
        sql(
          "UPDATE live_rooms SET heartbeat_at = now() " <>
            "WHERE owner = $1 AND code = ANY($2) RETURNING code",
          [owner, codes]
        )

      {:ok, List.flatten(rows)}
    end)
  end

  @doc """
  Up to `limit` codes, other than `except`, of released rows and of rows
  whose owner stopped heartbeating.
  """
  @spec claimable(pos_integer(), [String.t()]) :: [String.t()]
  def claimable(limit, except) do
    result =
      run([], fn ->
        %{rows: rows} =
          sql(
            "SELECT code FROM live_rooms " <>
              "WHERE (owner IS NULL OR heartbeat_at < now() - #{@stale}) AND code <> ALL($2) " <>
              "ORDER BY updated_at LIMIT $1",
            [limit, except]
          )

        List.flatten(rows)
      end)

    if is_list(result), do: result, else: []
  end

  @doc """
  Takes a room over at the next epoch. `:free` takes only a released or
  stale row, or one this owner holds already (a claim whose answer was lost);
  `:force` takes it from a live owner too, which is what a player asking this
  node for the room means. `{:held, room}` with the stored room (nil if not
  saved yet) if a live owner keeps it, `:none` if there is no such room.
  """
  @spec claim(String.t(), owner(), :free | :force) ::
          {:ok, claimed()} | {:held, map() | nil} | :none | :error
  def claim(code, owner, mode) do
    run(:none, fn ->
      case sql(
             "UPDATE live_rooms SET owner = $2, epoch = epoch + 1, heartbeat_at = now() " <>
               "WHERE code = $1 " <>
               "AND ($3 OR owner IS NULL OR owner = $2 OR heartbeat_at < now() - #{@stale}) " <>
               "RETURNING epoch, game_instance_id, room",
             [code, owner, mode == :force]
           ) do
        %{rows: [[epoch, game_instance_id, room]]} ->
          {:ok, %{epoch: epoch, game_instance_id: game_instance_id, room: room}}

        %{rows: []} ->
          case sql("SELECT room FROM live_rooms WHERE code = $1", [code]) do
            %{rows: [[room]]} -> {:held, room}
            %{rows: []} -> :none
          end
      end
    end)
  end

  @doc "Gives up rooms this owner holds, each at the epoch it holds it."
  @spec release(owner(), %{String.t() => pos_integer()}) :: :ok | :error
  def release(owner, epochs) do
    {codes, numbers} = epochs |> Enum.to_list() |> Enum.unzip()

    run(:ok, fn ->
      sql(
        "UPDATE live_rooms SET owner = NULL FROM unnest($2::text[], $3::bigint[]) AS held(code, epoch) " <>
          "WHERE live_rooms.code = held.code AND live_rooms.epoch = held.epoch AND owner = $1",
        [owner, codes, numbers]
      )

      :ok
    end)
  end

  @doc "The stored rooms this owner does not hold, as `{code, room}`, for reading only."
  @spec others(owner()) :: {:ok, [{String.t(), map()}]} | :error
  def others(owner) do
    run({:ok, []}, fn ->
      %{rows: rows} =
        sql(
          "SELECT code, room FROM live_rooms WHERE owner IS DISTINCT FROM $1 AND room IS NOT NULL",
          [owner]
        )

      {:ok, Enum.map(rows, fn [code, room] -> {code, room} end)}
    end)
  end

  @doc "Whether an open room still runs this game instance, on any node. Unknown counts as yes."
  @spec live_instance?(String.t()) :: boolean()
  def live_instance?(game_instance_id) do
    run(false, fn ->
      %{rows: [[live?]]} =
        sql("SELECT EXISTS (SELECT 1 FROM live_rooms WHERE game_instance_id = $1)", [
          game_instance_id
        ])

      live?
    end) != false
  end

  @doc "The room as stored: no timers, processes, talk, bot talk cursor or game summary."
  @spec encode(Room.t()) :: map()
  def encode(%Room{} = room) do
    budget =
      if room.paused_turn do
        elapsed = System.monotonic_time(:millisecond) - room.paused_turn.started_at_mono

        room.turn_pause_budget
        |> Map.update!(:remaining_ms, &max(0, &1 - elapsed))
        |> Map.put(:paused_since_ms, System.system_time(:millisecond))
      else
        room.turn_pause_budget
      end

    seats =
      Map.new(room.seats, fn {position, seat} ->
        {position,
         %{
           seat
           | bot_pid: nil,
             background_token: nil,
             pending_ping: nil,
             liveness_enabled: false,
             missed_pings: 0
         }}
      end)

    Serialization.encode(%{
      room
      | seats: seats,
        phase_timers: %{},
        turn_timer: nil,
        paused_turn: nil,
        turn_pause_budget: budget,
        talk: [],
        last_game_talk: [],
        # What changes with every move stays out, so a move saves nothing.
        bot_talk: %{room.bot_talk | seen: nil, shown_until: 0, phase: nil, turn: nil},
        game: nil
    })
  end

  @doc "A stored room, with the runtime fields at their defaults."
  @spec decode(map()) :: Room.t()
  def decode(json), do: value(json, nil)

  # Kept as JSON: a summary only ever goes back out to the client as JSON.
  defp value(json, "post_game_summaries"), do: json

  defp value(nil, "table_outcome"), do: nil

  defp value(json, "table_outcome"),
    do: Map.new(json, fn {key, item} -> {String.to_existing_atom(key), value(item, key)} end)

  defp value(json, "participants"),
    do:
      Map.new(json, fn {id, client} ->
        {id, Map.new(client, fn {key, item} -> {String.to_existing_atom(key), item} end)}
      end)

  defp value(json, key) when key in ["rtt_histogram", "network_ms"], do: json
  defp value(nil, "connection_stats"), do: nil

  defp value(json, "connection_stats"),
    do: Map.new(json, fn {key, item} -> {String.to_existing_atom(key), value(item, key)} end)

  defp value(history, "auto_played_turns") do
    Enum.map(history, fn %{
                           "$tuple" => [
                             %{"$tuple" => [%{"$tuple" => [instance, seq]}, user]},
                             action
                           ]
                         } ->
      {{{instance, seq}, user}, value(action, "action")}
    end)
  end

  defp value(nil, _key), do: nil
  defp value(json, _key) when is_boolean(json) or is_number(json), do: json
  defp value(%{"$integer" => integer}, _key), do: String.to_integer(integer)
  defp value(%{"$set" => items}, key), do: MapSet.new(value(items, key))
  defp value(%{"$tuple" => items}, key), do: List.to_tuple(value(items, key))

  defp value(%{"$struct" => module} = json, _key) do
    fields =
      for {field, item} <- Map.delete(json, "$struct"),
          into: %{},
          do: {String.to_existing_atom(field), value(item, field)}

    struct!(Map.fetch!(@structs, module), fields)
  end

  defp value(json, key) when is_map(json),
    do: Map.new(json, fn {name, item} -> {String.to_existing_atom(name), value(item, key)} end)

  defp value(json, key) when is_list(json), do: Enum.map(json, &value(&1, key))
  defp value(json, key) when key in @strings, do: json

  defp value(json, key) when key in @times or binary_part(key, byte_size(key) - 3, 3) == "_at" do
    {:ok, time, 0} = DateTime.from_iso8601(json)
    time
  end

  defp value(json, _key), do: String.to_existing_atom(json)

  defp sql(statement, params), do: Repo.query!(statement, params, timeout: @timeout)

  defp run(disabled, fun) do
    if enabled?(), do: fun.(), else: disabled
  rescue
    error ->
      Logger.warning("Room store unavailable: #{Exception.message(error)}")
      :error
  catch
    :exit, _ ->
      Logger.warning("Room store unavailable: timed out")
      :error
  end
end
