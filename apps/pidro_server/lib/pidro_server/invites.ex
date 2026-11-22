defmodule PidroServer.Invites do
  @moduledoc """
  Invite links: minting, lookup, tombstones, the redemption ledger and the
  read-time state machine (R1–R3, R6–R8, R26).

  Every function here is a plain Ecto operation. Nothing calls the RoomManager:
  `state/2` takes a `room_lookup` function, so the HTTP layer passes
  `&RoomManager.get_room/1` and tests pass a stub, and no GenServer callback
  ever writes an invite row (KTD1). Funnel events that need request context
  (`created`, `revoked`, `guest_created`, `seat_claimed`) are written by their
  controllers through `record_event/2`; this module writes only the two it can
  attribute on its own, `guest_upgraded` (`record_upgrade/1`) and
  `game_completed` (`record_game_completed/1`).

  ## Attribute maps

  Mutations take atom-keyed maps built by the caller, never raw request
  params: `create_invite/2` reads `room_id`, `room_code`, `host_user_id`,
  `seat_hint` and `label`; `record_redemption/2` reads `user_id`, `position`,
  `platform` and `source`; `record_event/2` reads `kind`, `platform`,
  `ua_class` and `user_id`. `position` and `kind` may be atoms.

  ## The room lookup contract

  `room_lookup` is a one-arity function of the invite's `room_code` answering
  `{:ok, room}` or `{:error, reason}`. A room is a `%RoomManager.Room{}` (seats
  counted like `Positions.count/1`) or any map with a `seats_taken` integer;
  both carry `id`, `status` and `locked`. The room's `id` must equal the
  invite's `room_id`, so a recycled 4-character code never seats a stranger.

  ## Codes

  `create_invite/2` draws a code, redraws once if the row exists, then inserts
  with the unique index as the last word. The redraw is keyed on an existence
  check rather than on the constraint error because a failed insert poisons
  the enclosing Postgres transaction, and `regenerate/2` mints inside one.
  """

  import Ecto.Query
  require Logger

  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Invites.Codes
  alias PidroServer.Invites.Event
  alias PidroServer.Invites.Invite
  alias PidroServer.Invites.Redemption
  alias PidroServer.Repo

  @ttl_hours 24
  @code_attempts 2
  @invite_limit 20
  @seats_total 4
  @default_link_base_url "https://www.pidro.online/j"

  @typedoc "The derived invite state, in R3 priority order."
  @type state :: :revoked | :moved | :expired | :closed | :started | :locked | :full | :open

  @typedoc "Answers a room for a room code; see the module documentation."
  @type room_lookup :: (String.t() -> {:ok, map()} | {:error, term()})

  @doc """
  Mints an invite: a fresh code, a 24-hour expiry and the given room, host,
  hint and label (R1, R2).

  `opts[:generator]` replaces `Codes.generate/0`, which is how tests force a
  collision. Answers the changeset error when the second draw is taken too.
  """
  @spec create_invite(map(), keyword()) ::
          {:ok, Invite.t()}
          | {:error, :user_not_found | :profile_unavailable | Ecto.Changeset.t()}
  def create_invite(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    generator = Keyword.get(opts, :generator, &Codes.generate/0)

    with :ok <- ensure_recipient_unblocked(attrs) do
      insert_with_fresh_code(attrs, generator, @code_attempts)
    end
  end

  @doc """
  Creates or updates the active invite for this room, position and recipient,
  optionally superseding an earlier invite in the same transaction. Unbound
  links keep their original one-active-link-per-room behavior.

  Per-room transaction locks serialize the active-invite lookup, lifetime-cap
  check, insert and supersession so concurrent mint requests cannot create two
  active links or exceed the cap.
  """
  @spec mint_for_room(map(), Invite.t() | nil, keyword()) ::
          {:ok, Invite.t(), :created | :ok} | {:error, term()}
  def mint_for_room(attrs, superseded \\ nil, opts \\ [])
      when is_map(attrs) and is_list(opts) do
    room_id = Map.fetch!(attrs, :room_id)

    Repo.transaction(fn ->
      lock_rooms!([room_id, superseded && superseded.room_id])

      with :ok <- ensure_recipient_unblocked(attrs),
           {:ok, invite, status} <- upsert_active_invite(attrs, opts),
           :ok <- maybe_supersede(superseded, invite) do
        {invite, status}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {invite, status}} -> {:ok, invite, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Finds an invite by any spelling of its code (R2), with `:successor` preloaded
  for `next_code` (R4).
  """
  @spec get_by_code(term()) :: {:ok, Invite.t()} | {:error, :not_found}
  def get_by_code(input) do
    with {:ok, code} <- Codes.normalize(input),
         %Invite{} = invite <-
           Repo.one(from(i in Invite, where: i.code == ^code, preload: :successor)) do
      {:ok, invite}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The newest invite of the room that is neither revoked, expired nor
  superseded, or nil. A second mint updates this row; `note_invite/2` is
  recomputed from it.
  """
  @spec active_for_room(Ecto.UUID.t()) :: Invite.t() | nil
  def active_for_room(room_id) do
    now = DateTime.utc_now()

    Repo.one(
      from(i in Invite,
        where:
          i.room_id == ^room_id and is_nil(i.revoked_at) and is_nil(i.superseded_by) and
            i.expires_at > ^now,
        order_by: [desc: i.inserted_at, desc: i.id],
        limit: 1
      )
    )
  end

  @doc "Changes `seat_hint` and `label` in place (a second mint, R1); the code stays."
  @spec update_hint(Invite.t(), map()) :: {:ok, Invite.t()} | {:error, Ecto.Changeset.t()}
  def update_hint(%Invite{} = invite, attrs) when is_map(attrs) do
    invite |> Invite.changeset(attrs) |> Repo.update()
  end

  @doc "Sets `revoked_at` (R6). Idempotent: an already revoked invite keeps its timestamp."
  @spec revoke(Invite.t()) :: {:ok, Invite.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%Invite{revoked_at: %DateTime{}} = invite), do: {:ok, invite}

  def revoke(%Invite{} = invite) do
    invite |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update()
  end

  @doc """
  Revokes `old`, mints a successor with the same room, hint and label, and
  points `old` at it, in one transaction (R7, KD8). Answers the new invite.
  """
  @spec regenerate(Invite.t(), keyword()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | term()}
  def regenerate(%Invite{} = old, opts \\ []) when is_list(opts) do
    Repo.transaction(fn ->
      lock_rooms!([old.room_id])
      current = Repo.get!(Invite, old.id)

      with :ok <- ensure_regenerable(current),
           :ok <- ensure_capacity(current.room_id),
           {:ok, old} <- revoke(current),
           {:ok, new} <- create_invite(successor_attrs(old), opts),
           {:ok, _old} <- supersede(old, new) do
        new
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Points `old` at `new` without revoking it (play again, KD8): `old` reads
  `moved` while `new`'s table is waiting.
  """
  @spec supersede(Invite.t(), Invite.t()) ::
          {:ok, Invite.t()} | {:error, :self_reference | Ecto.Changeset.t()}
  def supersede(%Invite{id: id}, %Invite{id: id}), do: {:error, :self_reference}

  def supersede(%Invite{} = old, %Invite{id: new_id} = new) do
    old
    |> Ecto.Changeset.change(superseded_by: new_id)
    |> Ecto.Changeset.foreign_key_constraint(:superseded_by)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, %{updated | successor: new}}
      error -> error
    end
  end

  @doc """
  Writes the first redemption row for an invite/user pair and increments
  `redeem_count` in one transaction (R8). Concurrent repeats return the
  existing row without incrementing the count. Call it after the seat is taken
  (KTD3).
  """
  @spec record_redemption(Invite.t(), map()) ::
          {:ok, Redemption.t()} | {:error, Ecto.Changeset.t()}
  def record_redemption(%Invite{id: invite_id}, attrs) when is_map(attrs) do
    changeset = redemption_changeset(invite_id, attrs)

    Repo.transaction(fn ->
      case insert_redemption_once(changeset) do
        {:ok, redemption, :created} ->
          bump_redeem_count(invite_id)
          redemption

        {:ok, redemption, :existing} ->
          redemption

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Records a first-time seat claim atomically.

  The redemption row, `redeem_count` increment and `seat_claimed` event are
  written together. A concurrent repeat for the same invite/user pair returns
  `:existing` and writes nothing else.
  """
  @spec record_claim(Invite.t(), map()) ::
          {:ok, Redemption.t(), :created | :existing} | {:error, Ecto.Changeset.t()}
  def record_claim(%Invite{id: invite_id}, attrs) when is_map(attrs) do
    changeset = redemption_changeset(invite_id, attrs)

    Repo.transaction(fn ->
      case insert_redemption_once(changeset) do
        {:ok, redemption, :created} ->
          bump_redeem_count(invite_id)

          event_attrs = %{
            kind: "seat_claimed",
            user_id: redemption.user_id,
            platform: redemption.platform
          }

          case insert_claim_events(invite_id, redemption, event_attrs) do
            :ok -> {redemption, :created}
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {:ok, redemption, :existing} ->
          {redemption, :existing}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {redemption, status}} -> {:ok, redemption, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes one funnel event (R8); `kind` must be one of `Event.kinds/0`."
  @spec record_event(Invite.t(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def record_event(%Invite{id: invite_id}, attrs) when is_map(attrs) do
    insert_event(invite_id, attrs)
  end

  defp insert_claim_events(invite_id, redemption, seat_claimed_attrs) do
    attrs =
      if redemption.source == "typed" do
        [
          seat_claimed_attrs,
          %{
            kind: "code_typed",
            user_id: redemption.user_id,
            platform: redemption.platform
          }
        ]
      else
        [seat_claimed_attrs]
      end

    Enum.reduce_while(attrs, :ok, fn event_attrs, :ok ->
      case insert_event(invite_id, event_attrs) do
        {:ok, _event} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  Writes `guest_upgraded` on the invite of the user's latest redemption, for
  either way a guest becomes a saved player: the upgrade or a Classic claim.
  Nothing is written when the user never redeemed one; a failed write is
  logged, never surfaced.
  """
  @spec record_upgrade(Ecto.UUID.t()) :: :ok
  def record_upgrade(user_id) do
    with %Redemption{invite_id: invite_id} <- latest_redemption(user_id),
         {:error, reason} <- insert_event(invite_id, %{kind: "guest_upgraded", user_id: user_id}) do
      Logger.error("guest_upgraded event failed for #{user_id}: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Account deletion: revokes the user's active invites and nulls `label` (the
  only personal data an invite carries) on every invite they hosted (KTD8).
  Answers the number revoked.
  """
  @spec revoke_hosted(Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_hosted(user_id) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      {revoked, _} =
        Repo.update_all(
          from(i in Invite,
            where: i.host_user_id == ^user_id and is_nil(i.revoked_at) and i.expires_at > ^now
          ),
          set: [revoked_at: now, updated_at: now]
        )

      Repo.update_all(
        from(i in Invite, where: i.host_user_id == ^user_id and not is_nil(i.label)),
        set: [label: nil, updated_at: now]
      )

      revoked
    end)
  end

  @doc "Every invite ever minted for the room, revoked ones included (the R1 cap)."
  @spec count_for_room(Ecto.UUID.t()) :: non_neg_integer()
  def count_for_room(room_id) do
    Repo.aggregate(from(i in Invite, where: i.room_id == ^room_id), :count)
  end

  @doc "The distinct users who redeemed the invite."
  @spec redemption_user_ids(Invite.t() | Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def redemption_user_ids(%Invite{id: invite_id}), do: redemption_user_ids(invite_id)

  def redemption_user_ids(invite_id) when is_binary(invite_id) do
    Repo.all(
      from(r in Redemption, where: r.invite_id == ^invite_id, distinct: true, select: r.user_id)
    )
  end

  @doc """
  Writes one `game_completed` event per redemption of the room's invites (R8).
  Answers the number written.
  """
  @spec record_game_completed(Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def record_game_completed(room_id) do
    now = DateTime.utc_now()

    entries =
      from(r in Redemption,
        join: i in assoc(r, :invite),
        where: i.room_id == ^room_id,
        select: %{invite_id: r.invite_id, user_id: r.user_id}
      )
      |> Repo.all()
      |> Enum.map(
        &Map.merge(&1, %{
          id: Ecto.UUID.generate(),
          kind: "game_completed",
          platform: "unknown",
          inserted_at: now
        })
      )

    {count, _} = Repo.insert_all(Event, entries)
    {:ok, count}
  end

  @doc "The shareable link, `<link_base_url>/<code>` (R26)."
  @spec url(Invite.t()) :: String.t()
  def url(%Invite{code: code}), do: "#{link_base_url()}/#{code}"

  @doc """
  A player's share link, `/play/<slug>` on the invite link host, e.g.
  `https://www.pidro.online/play/bengt`.
  """
  @spec play_url(String.t()) :: String.t()
  def play_url(slug), do: site_url("/play/#{slug}")

  @doc """
  A path on the invite link host, e.g. `site_url("/get")` is
  `https://www.pidro.online/get`.
  """
  @spec site_url(String.t()) :: String.t()
  def site_url(path), do: link_base_url() |> URI.merge(path) |> URI.to_string()

  @doc "The origin's share template with the link and the dashed code (R26)."
  @spec share_text(Invite.t()) :: String.t()
  def share_text(%Invite{code: code} = invite) do
    "Come play Pidro with me 🃏 #{url(invite)} — code #{Codes.dashed(code)}"
  end

  @doc """
  Derives the invite state in the R3 order: `revoked`, `moved`, `expired`,
  `closed`, `started`, `locked`, `full`, `open`.

  `moved` needs the superseding invite's own state to be `open` or `full`, so a
  play-again link forwards only while the new table is waiting; a revoked and
  superseded invite (regenerate) reads `revoked`. The lookup runs only once the
  row-level answers are exhausted. The superseding row is read from the
  repository on every call (a preloaded `:successor` only serves `next_code`),
  so the answer never trusts a stale struct.
  """
  @spec state(Invite.t(), room_lookup()) :: state()
  def state(%Invite{} = invite, room_lookup) when is_function(room_lookup, 1) do
    cond do
      invite.revoked_at != nil -> :revoked
      moved?(invite, room_lookup) -> :moved
      expired?(invite) -> :expired
      true -> room_state(invite, room_lookup)
    end
  end

  defp insert_with_fresh_code(attrs, generator, attempts_left) do
    code = generator.()

    if attempts_left > 1 and code_taken?(code) do
      insert_with_fresh_code(attrs, generator, attempts_left - 1)
    else
      attrs |> new_invite(code) |> Repo.insert()
    end
  end

  defp upsert_active_invite(attrs, opts) do
    room_id = Map.fetch!(attrs, :room_id)
    position = Map.get(attrs, :position)
    invited_user_id = Map.get(attrs, :invited_user_id)
    now = DateTime.utc_now()

    active =
      Repo.all(
        from(i in Invite,
          where:
            i.room_id == ^room_id and is_nil(i.revoked_at) and is_nil(i.superseded_by) and
              i.expires_at > ^now,
          order_by: [desc: i.inserted_at, desc: i.id]
        )
      )
      |> Enum.find(&(&1.position == position and &1.invited_user_id == invited_user_id))

    case active do
      %Invite{} = active ->
        with {:ok, invite} <- update_hint(active, Map.take(attrs, [:seat_hint, :label])) do
          {:ok, invite, :ok}
        end

      nil ->
        with :ok <- ensure_capacity(Map.fetch!(attrs, :room_id)),
             {:ok, invite} <- create_invite(attrs, opts) do
          {:ok, invite, :created}
        end
    end
  end

  defp maybe_supersede(nil, _invite), do: :ok

  defp maybe_supersede(%Invite{} = old, %Invite{} = new) do
    with {:ok, _old} <- supersede(old, new), do: :ok
  end

  defp ensure_recipient_unblocked(attrs) do
    if PidroServer.Blocks.blocked?(attrs[:host_user_id], attrs[:invited_user_id]),
      do: {:error, :user_not_found},
      else: :ok
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Block lookup failed: #{Exception.message(error)}")
      {:error, :profile_unavailable}
  end

  defp ensure_regenerable(%Invite{revoked_at: nil}), do: :ok
  defp ensure_regenerable(%Invite{}), do: {:error, :invite_revoked}

  defp ensure_capacity(room_id) do
    if count_for_room(room_id) < @invite_limit,
      do: :ok,
      else: {:error, :invite_limit}
  end

  # The UUID is hashed into Postgres' bigint advisory-lock namespace. Hash
  # collisions merely serialize unrelated rooms; they cannot weaken safety.
  defp lock_rooms!(room_ids) do
    room_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn room_id ->
      {:ok, _result} =
        Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [room_id])
    end)
  end

  defp code_taken?(code), do: Repo.exists?(from(i in Invite, where: i.code == ^code))

  defp new_invite(attrs, code) do
    %Invite{
      code: code,
      room_id: Map.get(attrs, :room_id),
      room_code: Map.get(attrs, :room_code),
      host_user_id: Map.get(attrs, :host_user_id),
      invited_user_id: Map.get(attrs, :invited_user_id),
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_hours, :hour)
    }
    |> Invite.changeset(attrs)
  end

  defp successor_attrs(%Invite{} = old) do
    Map.take(old, [
      :room_id,
      :room_code,
      :host_user_id,
      :seat_hint,
      :label,
      :position,
      :invited_user_id
    ])
  end

  defp bump_redeem_count(invite_id) do
    Repo.update_all(
      from(i in Invite, where: i.id == ^invite_id),
      inc: [redeem_count: 1],
      set: [updated_at: DateTime.utc_now()]
    )
  end

  defp redemption_changeset(invite_id, attrs) do
    %Redemption{invite_id: invite_id, user_id: Map.get(attrs, :user_id)}
    |> Redemption.changeset(stringify(attrs, :position))
  end

  defp insert_redemption_once(changeset) do
    if changeset.valid? do
      invite_id = Ecto.Changeset.get_field(changeset, :invite_id)
      user_id = Ecto.Changeset.get_field(changeset, :user_id)

      {:ok, _result} =
        Repo.query(
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["invite-redemption:#{invite_id}:#{user_id}"]
        )

      case Repo.get_by(Redemption, invite_id: invite_id, user_id: user_id) do
        %Redemption{} = redemption -> {:ok, redemption, :existing}
        nil -> map_inserted_redemption(Repo.insert(changeset))
      end
    else
      {:error, changeset}
    end
  end

  defp map_inserted_redemption({:ok, %Redemption{} = redemption}),
    do: {:ok, redemption, :created}

  defp map_inserted_redemption({:error, changeset}), do: {:error, changeset}

  defp insert_event(invite_id, attrs) do
    %Event{invite_id: invite_id, user_id: Map.get(attrs, :user_id)}
    |> Event.changeset(stringify(attrs, :kind))
    |> Repo.insert()
  end

  defp latest_redemption(user_id) do
    Repo.one(
      from(r in Redemption,
        where: r.user_id == ^user_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
      )
    )
  end

  # Atoms such as `:south` or `:seat_claimed` become strings; nil and strings pass through.
  defp stringify(attrs, key) do
    case Map.get(attrs, key) do
      value when is_atom(value) and not is_nil(value) ->
        Map.put(attrs, key, Atom.to_string(value))

      _other ->
        attrs
    end
  end

  defp link_base_url do
    :pidro_server
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:link_base_url, @default_link_base_url)
    |> String.trim_trailing("/")
  end

  defp moved?(%Invite{superseded_by: nil}, _room_lookup), do: false

  defp moved?(%Invite{} = invite, room_lookup) do
    case successor(invite) do
      nil -> false
      %Invite{} = successor -> state(successor, room_lookup) in [:open, :full]
    end
  end

  # Always read the successor afresh: a preloaded `:successor` may predate its
  # own revoke or supersede, and `moved` must never outlive the new table.
  defp successor(%Invite{superseded_by: id}), do: Repo.get(Invite, id)

  defp expired?(%Invite{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp room_state(%Invite{room_id: room_id, room_code: room_code}, room_lookup) do
    case room_lookup.(room_code) do
      {:ok, room} -> live_room_state(room, room_id)
      {:error, _reason} -> :closed
    end
  end

  defp live_room_state(room, room_id) do
    status = Map.get(room, :status)

    cond do
      Map.get(room, :id) != room_id -> :closed
      status == :closed -> :closed
      status in [:playing, :finished] -> :started
      Map.get(room, :locked) == true -> :locked
      seats_taken(room) >= @seats_total -> :full
      true -> :open
    end
  end

  defp seats_taken(%Room{} = room), do: Positions.count(room)
  defp seats_taken(%{seats_taken: taken}) when is_integer(taken), do: taken
end
