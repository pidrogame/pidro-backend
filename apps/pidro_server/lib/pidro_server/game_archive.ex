defmodule PidroServer.GameArchive do
  @moduledoc """
  Private, versioned game evidence. No client-facing routes or broadcasts.
  Readers are trusted server callers; an admin UI must require the existing
  admin session before calling these functions. See archive-contract.md.
  """
  import Ecto.Query
  require Logger

  alias PidroServer.GameArchive.{Archive, Event, Serialization}
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Repo

  @summary_fields ~w(game_instance_id room_code format_version versions participants status
    termination_reason last_revision started_at saved_at ended_at evidence_status
    failed_checkpoints missing_revision_count user_ids participation_truncated)a
  @capture_metadata [
    :initial_snapshot,
    :initial_deal,
    :failures,
    :participant_user_ids,
    :participation_truncated
  ]

  @doc "Initial seat facts only: no PID, credential, email, or room password."
  @spec participants(map()) :: map()
  def participants(seats),
    do: Map.new(seats, fn {position, seat} -> {position, Seat.serialize(seat)} end)

  @doc false
  @spec track_participants(String.t(), map()) :: :ok | {:error, term()}
  def track_participants(room, seats) do
    users = for {_pos, %{occupant_type: :human, user_id: id}} <- seats, do: id

    with {:ok, pid} <- PidroServer.Games.GameRegistry.lookup(room) do
      GenServer.call(pid, {:archive_participants, users}, 200)
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Best-effort live capture, capped at 50ms with one isolated task per game call and no retry queue."
  @spec capture(String.t(), map(), map(), map()) :: :ok | {:error, :unavailable}
  def capture(room, participants, snapshot, cause) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = write_capture(room, participants, snapshot, cause)
        send(caller, {tag, result})
      end)

    case await_capture(pid, monitor, tag, 50) do
      :ok -> :ok
      _ -> capture_failed(snapshot, cause)
    end
  rescue
    _ -> capture_failed(snapshot, cause)
  catch
    _, _ -> capture_failed(snapshot, cause)
  end

  defp write_capture(room, participants, snapshot, cause) do
    case write(room, participants, snapshot, event(cause), nil, "40ms", 2_000) do
      {:ok, _} -> closed(snapshot, cause)
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  @doc """
  The checkpoint a room's game must save before it applies a transition:
  synchronous, and only while `fence` (the room's owner and epoch in
  `live_rooms`) still holds the room. `{:error, :fenced}` means this game may
  not go on here: another node has taken the room over, or the database holds
  a revision this game never acknowledged.
  """
  @spec commit(String.t(), map(), map(), map(), {String.t(), pos_integer()}) ::
          :ok | {:error, :fenced | :unavailable}
  # A resumed game closed before its first move has nothing new to write.
  def commit(_room, _participants, snapshot, %{kind: :closed, last_cause: nil} = cause, _fence),
    do: closed(snapshot, cause)

  # Capped well inside a player's 250 ms move call, so a move whose commit
  # landed is always broadcast; a capped write that landed anyway shows up as
  # a conflicting revision on the next one.
  def commit(room, participants, snapshot, cause, fence) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(caller, {tag, write_commit(room, participants, snapshot, cause, fence)})
      end)

    await_capture(pid, monitor, tag, 150)
  end

  defp write_commit(room, participants, snapshot, cause, fence) do
    case write(room, participants, snapshot, event(cause), fence, "100ms", 1_000) do
      {:ok, _} -> closed(snapshot, cause)
      {:error, :fenced} -> {:error, :fenced}
      # A write that timed out here but committed there: the database is ahead
      # of this game, so the room has to come back from the database too.
      {:error, :conflicting_revision} -> {:error, :fenced}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp event(%{kind: :closed} = cause),
    do: Map.merge(cause.last_cause, Map.take(cause, @capture_metadata))

  defp event(cause), do: cause

  defp closed(snapshot, %{kind: :closed}) do
    finalize(snapshot.game_instance_id, "closed", "room_closed")
    :ok
  end

  defp closed(_snapshot, _cause), do: :ok

  defp await_capture(pid, monitor, tag, cap_ms) do
    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :unavailable}
    after
      cap_ms ->
        Process.exit(pid, :kill)
        # DOWN follows any result from this worker. Drain both so a late reply
        # cannot become an unexpected message in the game GenServer.
        receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
        receive do: ({^tag, _} -> :ok), after: (0 -> :ok)
        {:error, :unavailable}
    end
  end

  @doc "Private live archive health, never included in client snapshots."
  @spec health(String.t()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def health(room) do
    with {:ok, pid} <- PidroServer.Games.GameRegistry.lookup(room) do
      {:ok, GenServer.call(pid, :archive_health, 1_000)}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Writes a checkpoint atomically; raises on failure. Use capture/4 in the live game."
  @spec checkpoint!(String.t(), map(), map(), map()) :: :ok
  def checkpoint!(room_code, participants, snapshot, cause) do
    case write(room_code, participants, snapshot, cause, nil, "40ms", 2_000) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "archive checkpoint rejected: #{reason}"
    end
  end

  defp write(room_code, participants, snapshot, cause, fence, statement_timeout, timeout) do
    now = DateTime.utc_now()
    data = encode_snapshot(snapshot)

    payload =
      cause |> Map.drop(@capture_metadata) |> Serialization.encode()

    failures = Map.get(cause, :failures, 0)
    initial = Map.get(cause, :initial_snapshot, snapshot)

    Repo.transaction(
      fn ->
        # Bound server-side work too: killing the client task alone does not
        # guarantee PostgreSQL immediately stops a blocked statement.
        %{rows: [[previous_timeout]]} = Repo.query!("SHOW statement_timeout")
        Repo.query!("SET LOCAL statement_timeout = '#{statement_timeout}'")
        hold!(fence, room_code, snapshot.game_instance_id)

        unless Repo.exists?(
                 from a in Archive, where: a.game_instance_id == ^snapshot.game_instance_id
               ) do
          insert_initial(room_code, participants, initial, encode_snapshot(initial), now)
        end

        archive =
          Repo.one!(
            from a in Archive,
              where: a.game_instance_id == ^snapshot.game_instance_id,
              lock: "FOR UPDATE"
          )

        save_revision(archive, snapshot, data, payload, failures, now)
        save_participation(archive, cause)

        if is_nil(archive.initial_deal) and cause[:initial_deal] do
          deal = encode_snapshot(cause.initial_deal)

          Repo.update_all(
            from(a in Archive, where: a.game_instance_id == ^snapshot.game_instance_id),
            set: [initial_deal: deal]
          )
        end

        # Preserve an enclosing transaction's setting (including SQL Sandbox).
        Repo.query!("SELECT set_config('statement_timeout', $1, true)", [previous_timeout])
      end,
      timeout: timeout
    )
  end

  # The fence: this row lock serializes the write with a takeover, which bumps
  # the epoch, so a write from the room's previous owner can never land.
  defp hold!(nil, _room_code, _id), do: :ok

  defp hold!({owner, epoch}, room_code, id) do
    %{num_rows: rows} =
      Repo.query!(
        "UPDATE live_rooms SET game_instance_id = $4 WHERE code = $1 AND owner = $2 AND epoch = $3",
        [room_code, owner, epoch, id]
      )

    if rows == 0, do: Repo.rollback(:fenced)
  end

  @doc "Idempotently closes an active archive. Complete evidence is never relabelled."
  @spec finalize(String.t(), String.t(), String.t()) :: {non_neg_integer(), nil}
  def finalize(id, status, reason) when status in ["closed", "interrupted"] do
    now = DateTime.utc_now()

    query =
      from a in Archive,
        where: a.game_instance_id == ^id and a.status == "active",
        update: [
          set: [
            status: ^status,
            termination_reason: ^reason,
            ended_at: ^now,
            evidence_status:
              fragment(
                "CASE WHEN ? = 'interrupted' AND ? = 'continuous' THEN 'uncertain' ELSE ? END",
                ^status,
                a.evidence_status,
                a.evidence_status
              )
          ]
        ]

    Repo.update_all(query, [])
  end

  @doc "Search metadata by :from/:to (start time), :user_id, :room_code, :game_instance_id, :status."
  @spec search(keyword()) :: [map()]
  def search(opts \\ []) do
    query = Enum.reduce(opts, Archive, &filter/2)

    Repo.all(
      from a in query,
        order_by: [desc: a.started_at, desc: a.game_instance_id],
        limit: ^limit(opts),
        select: map(a, ^@summary_fields)
    )
  end

  @doc "Returns summary metadata, or nil. Does not load private snapshots."
  @spec get(String.t()) :: map() | nil
  def get(id), do: summary(id)

  @doc "Alias for get/1."
  @spec summary(String.t()) :: map() | nil
  def summary(id),
    do:
      Repo.one(
        from a in Archive, where: a.game_instance_id == ^id, select: map(a, ^@summary_fields)
      )

  @doc "Returns a saved checkpoint by exact revision, :latest, :initial, or :initial_deal; nil if unavailable."
  @spec snapshot(String.t(), non_neg_integer() | :latest | :initial | :initial_deal) ::
          map() | nil
  def snapshot(id, revision \\ :latest)
  def snapshot(id, :latest), do: last_snapshot(id)
  def snapshot(id, :initial), do: initial_snapshot(id)
  def snapshot(id, :initial_deal), do: initial_deal(id)

  def snapshot(id, revision) when is_integer(revision) and revision >= 0,
    do:
      Repo.one(
        from e in Event,
          where: e.game_instance_id == ^id and e.revision == ^revision,
          select: e.snapshot
      )

  @doc "Next saved event/checkpoint after a revision, or nil. This does not execute the engine."
  @spec step(String.t(), integer()) :: Event.t() | nil
  def step(id, after_revision),
    do: id |> events(after_revision: after_revision, limit: 1) |> List.first()

  @doc "Durable seated participation for an exact instance/room/user triple; no live-room fallback."
  @spec participant?(String.t(), String.t(), String.t()) :: boolean()
  def participant?(id, room, user) when is_binary(id) and is_binary(room) and is_binary(user) do
    Repo.exists?(
      from a in Archive,
        where:
          a.game_instance_id == ^id and a.room_code == ^room and
            fragment("? @> ARRAY[?]::text[]", a.user_ids, ^user)
    )
  end

  def participant?(_, _, _), do: false

  @doc "Returns the last saved data-only snapshot, or nil; it is never a live-state promise."
  @spec last_snapshot(String.t()) :: map() | nil
  def last_snapshot(id),
    do: Repo.one(from a in Archive, where: a.game_instance_id == ^id, select: a.last_snapshot)

  @doc """
  The last saved checkpoint of a room's game, decoded into a state a
  `Pidro.Server` continues from: `%{game_instance_id, state_revision, state}`.
  A checkpoint holds no engine events, so they are folded back from each
  revision's own. `:not_active` for a game not of this room, or in none of
  `statuses` (a finished room's game is `"complete"`).
  """
  @spec resume(String.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, :not_found | :not_active}
  def resume(id, room_code, statuses) do
    archive =
      Repo.one(
        from a in Archive,
          where: a.game_instance_id == ^id,
          select: %{status: a.status, room_code: a.room_code, snapshot: a.last_snapshot}
      )

    with %{status: status, room_code: ^room_code, snapshot: snapshot} <- archive,
         true <- status in statuses,
         %{"state" => state, "state_revision" => revision} <- snapshot do
      payloads =
        Repo.all(
          from e in Event,
            where: e.game_instance_id == ^id,
            order_by: e.revision,
            select: e.payload
        )

      events =
        Enum.reduce(payloads, [], fn payload, events ->
          added = Serialization.decode_game(payload["engine_events"] || [])
          if payload["events_replaced"], do: added, else: events ++ added
        end)

      game = %{Serialization.decode_game(state) | events: events}
      {:ok, %{game_instance_id: id, state_revision: revision, state: game}}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :not_active}
    end
  end

  @doc "Returns the pre-action initial snapshot, or nil. The first deal is a timeline checkpoint."
  @spec initial_snapshot(String.t()) :: map() | nil
  def initial_snapshot(id),
    do: Repo.one(from a in Archive, where: a.game_instance_id == ^id, select: a.initial_snapshot)

  @doc "Returns the first actual deal (hands, remaining deck and cuts), or nil if not saved."
  @spec initial_deal(String.t()) :: map() | nil
  def initial_deal(id),
    do: Repo.one(from a in Archive, where: a.game_instance_id == ^id, select: a.initial_deal)

  @doc "Ordered revision history; exclusive :after_revision cursor (-1 by default), :limit 1..100."
  @spec events(String.t(), keyword()) :: [Event.t()]
  def events(id, opts \\ []) do
    cursor = Keyword.get(opts, :after_revision, -1)

    Repo.all(
      from e in Event,
        where: e.game_instance_id == ^id and e.revision > ^cursor,
        order_by: e.revision,
        limit: ^limit(opts)
    )
  end

  @doc "Deletes at most :batch_size terminal archives older than :retention_days (default 30). Never touches stats."
  @spec cleanup(keyword()) :: {non_neg_integer(), nil}
  def cleanup(opts \\ []) do
    days = bounded!(Keyword.get(opts, :retention_days, 30), 1, 3650)
    batch = bounded!(Keyword.get(opts, :batch_size, 100), 1, 1000)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    ids =
      from a in Archive,
        where: a.status != "active" and a.ended_at < ^cutoff,
        order_by: [a.ended_at, a.game_instance_id],
        limit: ^batch,
        select: a.game_instance_id

    Repo.delete_all(from a in Archive, where: a.game_instance_id in subquery(ids))
  end

  @doc """
  What the archive knows of each bot persona from its seats: games since
  `week_start`, all games, games with a winner, wins, and its first game.
  A game where the persona sat on both teams has no side, so it is neither
  decided nor won for it.
  """
  @spec persona_tallies(DateTime.t()) :: %{String.t() => map()}
  def persona_tallies(week_start) do
    games =
      from a in Archive,
        join: s in fragment("jsonb_each(?)", a.participants),
        on: true,
        where:
          fragment(
            "?->>'occupant_type' = 'bot' AND ?->>'bot_persona' IS NOT NULL",
            s.value,
            s.value
          ),
        group_by: [a.game_instance_id, fragment("?->>'bot_persona'", s.value)],
        select: %{
          persona: fragment("?->>'bot_persona'", s.value),
          started_at: a.started_at,
          winner: fragment("?->'state'->>'winner'", a.last_snapshot),
          team:
            fragment(
              "CASE WHEN bool_and(? IN ('north', 'south')) THEN 'north_south' WHEN bool_and(? IN ('east', 'west')) THEN 'east_west' END",
              s.key,
              s.key
            )
        }

    Repo.all(
      from g in subquery(games),
        group_by: g.persona,
        select:
          {g.persona,
           %{
             week: filter(count(), g.started_at >= ^week_start),
             all: count(),
             decided: filter(count(), not is_nil(g.winner) and not is_nil(g.team)),
             wins: filter(count(), g.winner == g.team),
             since: min(g.started_at)
           }}
    )
    |> Map.new()
  end

  defp insert_initial(room_code, participants, snapshot, data, now) do
    seats = Serialization.encode(participants)
    users = seats |> Map.values() |> Enum.map(& &1["user_id"]) |> Enum.reject(&is_nil/1)

    Repo.insert!(
      %Archive{
        game_instance_id: snapshot.game_instance_id,
        room_code: room_code,
        format_version: 1,
        versions: :persistent_term.get({__MODULE__, :versions}),
        participants: seats,
        user_ids: users,
        status: "active",
        evidence_status: "continuous",
        failed_checkpoints: 0,
        missing_revision_count: 0,
        last_revision: -1,
        initial_snapshot: data,
        last_snapshot: data,
        started_at: DateTime.from_unix!(snapshot.server_time_ms * 1_000, :microsecond),
        saved_at: now
      },
      on_conflict: :nothing
    )
  end

  defp save_revision(archive, snapshot, data, payload, failures, now) do
    revision = snapshot.state_revision

    cond do
      revision <= archive.last_revision ->
        existing =
          Repo.get_by!(Event, game_instance_id: archive.game_instance_id, revision: revision)

        if existing.snapshot != data or
             Map.delete(existing.payload, "missing_revisions") != payload,
           do: Repo.rollback(:conflicting_revision)

        archive |> Ecto.Changeset.change(failure_attrs(archive, failures)) |> Repo.update!()

      archive.status in ["closed", "interrupted"] ->
        Repo.rollback(:already_finalized)

      true ->
        missing = revision - archive.last_revision - 1

        payload =
          if missing > 0,
            do: Map.put(payload, "missing_revisions", [archive.last_revision + 1, revision - 1]),
            else: payload

        Repo.insert!(%Event{
          game_instance_id: archive.game_instance_id,
          revision: revision,
          occurred_at: DateTime.from_unix!(snapshot.server_time_ms * 1_000, :microsecond),
          saved_at: now,
          payload: payload,
          snapshot: data
        })

        attrs =
          [
            last_revision: revision,
            last_snapshot: data,
            saved_at: now,
            missing_revision_count: archive.missing_revision_count + missing
          ] ++ failure_attrs(archive, failures)

        attrs = if missing > 0, do: Keyword.put(attrs, :evidence_status, "partial"), else: attrs

        attrs =
          if snapshot.state.phase in [:complete, :game_over] and archive.status == "active",
            do:
              attrs ++ [status: "complete", termination_reason: "engine_complete", ended_at: now],
            else: attrs

        archive |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  defp failure_attrs(archive, failures) do
    status =
      if failures > 0 and archive.evidence_status == "continuous",
        do: "uncertain",
        else: archive.evidence_status

    [failed_checkpoints: max(archive.failed_checkpoints, failures), evidence_status: status]
  end

  defp save_participation(archive, cause) do
    users = Enum.uniq(archive.user_ids ++ Map.get(cause, :participant_user_ids, []))

    truncated =
      archive.participation_truncated or Map.get(cause, :participation_truncated, false) or
        length(users) > 256

    Repo.update_all(from(a in Archive, where: a.game_instance_id == ^archive.game_instance_id),
      set: [user_ids: Enum.take(users, 256), participation_truncated: truncated]
    )
  end

  defp encode_snapshot(snapshot) do
    snapshot
    |> Map.drop([:server_time_ms])
    |> Map.update!(:state, &Map.delete(&1, :events))
    |> Serialization.encode()
  end

  defp capture_failed(snapshot, cause) do
    failures = Map.get(cause, :failures, 0)

    if failures == 0 or Bitwise.band(failures, failures - 1) == 0 do
      Logger.warning(
        "Game archive unavailable instance=#{snapshot.game_instance_id} revision=#{snapshot.state_revision}; gameplay continues"
      )
    end

    :telemetry.execute([:pidro, :archive, :failure], %{count: 1}, %{})
    {:error, :unavailable}
  end

  defp filter({:from, value}, query), do: where(query, [a], a.started_at >= ^value)
  defp filter({:to, value}, query), do: where(query, [a], a.started_at < ^value)

  defp filter({:user_id, value}, query),
    do: where(query, [a], fragment("? @> ARRAY[?]::text[]", a.user_ids, ^value))

  defp filter({key, value}, query) when key in [:room_code, :game_instance_id, :status],
    do: where(query, [a], field(a, ^key) == ^value)

  defp filter({:before, {time, id}}, query),
    do:
      where(
        query,
        [a],
        a.started_at < ^time or (a.started_at == ^time and a.game_instance_id < ^id)
      )

  defp filter({:limit, _}, query), do: query

  defp limit(opts), do: bounded!(Keyword.get(opts, :limit, 50), 1, 100)

  defp bounded!(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: value

  defp bounded!(_, _, _), do: raise(ArgumentError, "archive option outside allowed bounds")

  @doc false
  @spec cache_versions() :: :ok
  def cache_versions do
    versions = %{
      "server" => to_string(Application.spec(:pidro_server, :vsn)),
      "engine" => to_string(Application.spec(:pidro_engine, :vsn)),
      "engine_code" => fingerprint(:pidro_engine),
      "server_code" => fingerprint(:pidro_server),
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version()
    }

    :persistent_term.put({__MODULE__, :versions}, versions)
  end

  defp fingerprint(app) do
    app
    |> Application.spec(:modules)
    |> Enum.sort()
    |> Enum.map(fn module ->
      Code.ensure_loaded!(module)
      [Atom.to_string(module), module.module_info(:md5)]
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
