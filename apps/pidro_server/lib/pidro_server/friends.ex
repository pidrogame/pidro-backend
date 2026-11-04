defmodule PidroServer.Friends do
  @moduledoc "Directed friendship edges, discovery and live player entries."
  import Ecto.Query

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Blocks
  alias PidroServer.ClassicSocial
  alias PidroServer.Friends.{Friendship, Ignore}
  alias PidroServer.Games.Room.{Positions, Seat}
  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Profiles
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats
  alias PidroServerWeb.Presence

  @doc """
  Sends a personal link's owner a friend request from the newly registered
  account, after registration commits, exactly as a request sent by hand. An
  owner who blocked or ignored the newcomer hears nothing, and nothing is sent.
  """
  @spec link_signup({:ok, User.t()} | {:error, term()}, term()) ::
          {:ok, User.t()} | {:error, term()}
  def link_signup({:ok, %User{guest: false} = user}, slug) when is_binary(slug) do
    with %User{id: friend_id} <- Auth.get_user_by_share_slug(slug),
         false <- ignored?(friend_id, user.id),
         {:ok, list} <- add(user.id, friend_id) do
      [owner] = entries([friend_id])
      join_as = Enum.find_value(list.friends, &(&1.user_id == friend_id && &1.join_as))
      {:ok, %{user | linked_friend: Map.put(owner, :join_as, join_as)}}
    else
      _skipped -> {:ok, user}
    end
  end

  def link_signup(result, _slug), do: result

  @doc """
  Adds one edge, idempotently, and returns the caller's full list. A new edge
  tells the other player live: a request, or the acceptance of theirs.
  """
  @spec add(String.t(), String.t()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def add(user_id, friend_id) do
    with {:ok, friend_id} <- target(user_id, friend_id),
         {:ok, owners} <-
           Repo.transaction(fn ->
             Blocks.lock_pair(user_id, friend_id)

             if Blocks.blocked?(user_id, friend_id), do: Repo.rollback(:user_not_found)

             owners =
               Repo.all(
                 from f in Friendship,
                   where:
                     (f.user_id == ^user_id and f.friend_id == ^friend_id) or
                       (f.user_id == ^friend_id and f.friend_id == ^user_id),
                   select: f.user_id
               )

             # Adding someone is answering them, so the caller's ignore of them ends.
             Repo.delete_all(ignores(user_id, friend_id))

             case Repo.insert(Friendship.changeset(user_id, friend_id),
                    on_conflict: :nothing,
                    conflict_target: [:user_id, :friend_id]
                  ) do
               {:ok, _} -> owners
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      changed([user_id, friend_id])

      if user_id not in owners and not ignored?(friend_id, user_id),
        do: tell(friend_id, user_id, friend_id in owners)

      {:ok, list(user_id)}
    end
  end

  @doc "Deletes the caller's edge, and the reverse edge only if they were friends."
  @spec remove(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def remove(user_id, friend_id) do
    with {:ok, friend_id} <- target(user_id, friend_id),
         {:ok, _} <-
           Repo.transaction(fn ->
             Blocks.lock_pair(user_id, friend_id)

             case Repo.delete_all(edge(user_id, friend_id)) do
               {0, _} -> :ok
               _ -> Repo.delete_all(edge(friend_id, user_id))
             end
           end) do
      changed([user_id, friend_id])
      {:ok, list(user_id)}
    end
  end

  @doc """
  Hides an incoming request from the caller only; the sender's edge stays. A
  request the sender cancels and sends again stays hidden too.
  """
  @spec ignore(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def ignore(user_id, friend_id) do
    with {:ok, friend_id} <- target(user_id, friend_id) do
      now = DateTime.utc_now()

      Repo.insert_all(
        Ignore,
        from(f in edge(friend_id, user_id),
          select: %{
            user_id: type(^user_id, :binary_id),
            ignored_id: f.user_id,
            inserted_at: type(^now, :utc_datetime_usec)
          }
        ),
        on_conflict: :nothing,
        conflict_target: [:user_id, :ignored_id]
      )

      changed([user_id])
      {:ok, list(user_id)}
    end
  end

  @doc "Undoes an ignore, restoring the incoming request."
  @spec unignore(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def unignore(user_id, friend_id) do
    with {:ok, friend_id} <- target(user_id, friend_id) do
      Repo.delete_all(ignores(user_id, friend_id))
      changed([user_id])
      {:ok, list(user_id)}
    end
  end

  @doc "Returns mutual friends, unignored incoming and outgoing-only edges, with live presence."
  @spec list(String.t()) :: map()
  def list(user_id) do
    sent =
      Repo.all(
        from f in Friendship,
          where: f.user_id == ^user_id,
          order_by: [desc: f.inserted_at, asc: f.friend_id],
          select: {f.friend_id, f.inserted_at}
      )

    received =
      Repo.all(
        from f in Friendship,
          where: f.friend_id == ^user_id,
          order_by: [desc: f.inserted_at, asc: f.user_id],
          select: {f.user_id, f.inserted_at}
      )

    ignored =
      MapSet.new(Repo.all(from i in Ignore, where: i.user_id == ^user_id, select: i.ignored_id))

    sent_at = Map.new(sent)
    received_at = Map.new(received)
    friend_ids = for {id, _} <- received, Map.has_key?(sent_at, id), do: id

    added_you_ids =
      for {id, _} <- received,
          not Map.has_key?(sent_at, id) and not MapSet.member?(ignored, id),
          do: id

    requested_ids = for {id, _} <- sent, not Map.has_key?(received_at, id), do: id
    entries = Map.new(entries(friend_ids ++ added_you_ids ++ requested_ids), &{&1.user_id, &1})
    pick = fn ids -> for id <- ids, entry = entries[id], do: entry end

    added_you =
      Enum.map(pick.(added_you_ids), &Map.put(&1, :requested_at, received_at[&1.user_id]))

    played_at = played_together_at(user_id, friend_ids)

    %{
      friends:
        Enum.sort_by(
          friend_ids
          |> pick.()
          |> Enum.map(&Map.put(&1, :played_together_at, played_at[&1.user_id]))
          |> with_join_as(user_id),
          &{&1.presence == "offline", User.name_key(&1.display_name), &1.user_id}
        ),
      added_you: added_you,
      requested: Enum.map(pick.(requested_ids), &Map.put(&1, :requested_at, sent_at[&1.user_id])),
      requests_waiting: length(added_you),
      waiting_for_you: length(added_you) + length(RoomManager.seat_invitations(user_id))
    }
    |> with_classic(user_id)
  end

  @doc """
  Sits `user` at their mutual friend's table, in the seat `RoomManager.friend_seat/4`
  picks, through the ordinary join so every admission rule still applies.
  """
  @spec join(User.t(), String.t()) ::
          {:ok, Room.t(), Positions.position()} | {:error, term()}
  def join(%User{} = user, friend_id) do
    with {:ok, friend_id} <- mutual(user.id, friend_id),
         %Room{} = room <- table(RoomManager.list_rooms(:available), friend_id),
         {position, _as} <-
           RoomManager.friend_seat(room, user.id, friend_id, games_played(user.id)) do
      RoomManager.join_room(room.code, user, position)
    else
      nil -> {:error, :no_seat_for_you}
      :no_table -> {:error, :room_not_found}
      error -> error
    end
  end

  @doc "Finds up to ten registered players by the existing folded-name prefix."
  @spec search(String.t(), term()) :: {:ok, [map()]} | {:error, :query_too_short}
  def search(user_id, query) when is_binary(query) do
    query = query |> String.normalize(:nfkc) |> String.trim()

    if String.length(query) < 3 do
      {:error, :query_too_short}
    else
      prefix = User.name_key(query)

      ids =
        from(u in User,
          where: u.guest == false and u.id != ^user_id,
          order_by: [asc: coalesce(u.display_name, u.username), asc: u.id],
          select: {u.id, coalesce(u.display_name, u.username)}
        )
        |> Blocks.excluding(user_id)
        |> Repo.all()
        |> Stream.filter(fn {_id, name} ->
          String.starts_with?(User.name_key(name) || "", prefix)
        end)
        |> Stream.map(&elem(&1, 0))
        |> Enum.take(10)

      {:ok, related_entries(user_id, ids)}
    end
  end

  def search(_user_id, _query), do: {:error, :query_too_short}

  @doc "Returns non-friend humans from the caller's last twenty completed games."
  @spec recent(String.t()) :: [map()]
  def recent(user_id) do
    outgoing = outgoing_ids(user_id)

    mutual =
      Repo.all(from f in Friendship, where: f.friend_id == ^user_id, select: f.user_id)
      |> Enum.filter(&MapSet.member?(outgoing, &1))
      |> MapSet.new()

    games =
      Repo.all(
        from g in GameStats,
          where: ^user_id in g.player_ids and not is_nil(g.completed_at),
          order_by: [desc: g.completed_at, desc: g.id],
          limit: 20,
          select: {g.player_ids, g.completed_at}
      )

    played_at =
      Enum.reduce(games, %{}, fn {ids, at}, acc ->
        Enum.reduce(ids, acc, &Map.put_new(&2, &1, at))
      end)

    ids =
      games
      |> Enum.flat_map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == user_id or MapSet.member?(mutual, &1)))

    visible =
      from(u in User, where: u.id in ^ids, select: u.id)
      |> Blocks.excluding(user_id)
      |> Repo.all()
      |> MapSet.new()

    related_entries(user_id, Enum.filter(ids, &MapSet.member?(visible, &1)))
    |> Enum.take(10)
    |> Enum.map(&Map.put(&1, :played_together_at, played_at[&1.user_id]))
  end

  defp with_classic(list, user_id) do
    case Repo.get(User, user_id) do
      %User{classic_user_id: id} when not is_nil(id) ->
        Map.put(list, :classic, %{not_here: ClassicSocial.not_here(id)})

      _ ->
        list
    end
  end

  # The friends list tells the app beforehand what join/2 will do.
  defp with_join_as(friends, user_id) do
    rooms = RoomManager.list_rooms(:available)
    tables = Map.new(friends, &{&1.user_id, table(rooms, &1.user_id)})
    games = if Enum.any?(Map.values(tables), &match?(%Room{}, &1)), do: games_played(user_id)

    Enum.map(friends, fn friend ->
      Map.put(friend, :join_as, join_as(tables[friend.user_id], user_id, friend.user_id, games))
    end)
  end

  # A locked table, a kick or a block with the host refuses the join itself.
  defp join_as(:no_table, _user_id, _friend_id, _games), do: nil

  defp join_as(%Room{} = room, user_id, friend_id, games) do
    with false <- room.locked or user_id in room.kicked_ids,
         false <- Blocks.blocked?(room.host_id, user_id),
         {_position, as} <- RoomManager.friend_seat(room, user_id, friend_id, games) do
      Atom.to_string(as)
    else
      _ -> nil
    end
  end

  defp table(rooms, friend_id),
    do: Enum.find(rooms, :no_table, &Seat.position_of(&1.seats, friend_id))

  defp games_played(user_id), do: Profiles.record(user_id).games

  defp mutual(user_id, friend_id) do
    with {:ok, id} <- Ecto.UUID.cast(friend_id),
         2 <-
           Repo.aggregate(
             from(f in Friendship,
               where:
                 (f.user_id == ^user_id and f.friend_id == ^id) or
                   (f.user_id == ^id and f.friend_id == ^user_id)
             ),
             :count
           ) do
      {:ok, id}
    else
      _ -> {:error, :user_not_found}
    end
  end

  defp target(user_id, friend_id) do
    with {:ok, id} <- Ecto.UUID.cast(friend_id),
         false <- id == user_id,
         %User{guest: false} <- Repo.get(User, id) do
      {:ok, id}
    else
      true -> {:error, :cannot_friend_self}
      _ -> {:error, :user_not_found}
    end
  end

  defp outgoing_ids(user_id) do
    Repo.all(from f in Friendship, where: f.user_id == ^user_id, select: f.friend_id)
    |> MapSet.new()
  end

  defp related_entries(user_id, ids) do
    outgoing = outgoing_ids(user_id)

    incoming =
      Repo.all(from f in Friendship, where: f.friend_id == ^user_id, select: f.user_id)
      |> MapSet.new()

    Enum.map(entries(ids), fn entry ->
      relation =
        case {MapSet.member?(outgoing, entry.user_id), MapSet.member?(incoming, entry.user_id)} do
          {true, true} -> "friend"
          {false, true} -> "added_you"
          {true, false} -> "added"
          {false, false} -> "none"
        end

      Map.put(entry, :relation, relation)
    end)
  end

  defp entries(ids) do
    users = Auth.get_users_map(ids)
    lobby = Presence.list("lobby")

    games = for room <- RoomManager.list_rooms(), do: {room, Presence.list("game:" <> room.code)}
    tables = games |> Enum.flat_map(&seated_company/1) |> Map.new()
    watching = games |> Enum.flat_map(fn {_room, connected} -> Map.keys(connected) end)
    connected = lobby |> Map.keys() |> Enum.concat(watching) |> MapSet.new()

    for id <- ids, user = users[id], user && user.guest == false do
      entry = %{
        user_id: id,
        display_name: User.public_name(user),
        avatar_url: user.avatar_url,
        level: user.level,
        prestige: user.prestige,
        presence: "offline"
      }

      cond do
        table = tables[id] ->
          {company, room} = table

          Map.merge(entry, %{
            presence: "at_table",
            table_company: company,
            table_open_seats: length(RoomManager.available_positions(room)),
            table_hand: if(room.status == :playing, do: room.game[:hand])
          })

        MapSet.member?(connected, id) ->
          %{entry | presence: "online"}

        true ->
          entry
      end
    end
  end

  # Connected players holding a human seat, with whether anyone else human sits
  # there. Only a started game can be with bots; a table that has not started is
  # one with open seats, whoever sits there. A connected spectator holds no seat
  # and stays online.
  defp seated_company({room, connected}) do
    for {_, %{occupant_type: :human, user_id: id}} <- room.seats, Map.has_key?(connected, id) do
      {id, {company(room, id), room}}
    end
  end

  defp company(%{status: status} = room, id) when status in [:playing, :finished] do
    if Seat.alone_with_bots?(room.seats, id), do: "bots", else: "people"
  end

  defp company(_waiting, _id), do: "people"

  defp edge(user_id, friend_id),
    do: from(f in Friendship, where: f.user_id == ^user_id and f.friend_id == ^friend_id)

  defp ignores(user_id, ignored_id),
    do: from(i in Ignore, where: i.user_id == ^user_id and i.ignored_id == ^ignored_id)

  defp ignored?(user_id, ignored_id), do: Repo.exists?(ignores(user_id, ignored_id))

  # Only the new edge's recipient hears of it: a request, or their request accepted.
  defp tell(recipient_id, user_id, accepted?) do
    for player <- entries([user_id]) do
      {event, payload} =
        if accepted?,
          do:
            {"friend_accepted",
             %{player: hd(with_join_as([player], recipient_id)), source: "accept"}},
          else:
            {"friend_request",
             %{
               player: player,
               played_together_at: played_together_at(user_id, [recipient_id])[recipient_id]
             }}

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "lobby:updates",
        {:friend_event, recipient_id, event, payload}
      )
    end
  end

  defp played_together_at(_user_id, []), do: %{}

  defp played_together_at(user_id, ids) do
    Repo.all(
      from g in GameStats,
        join: u in User,
        on: u.id in g.player_ids,
        # `@>` lets the GIN index on player_ids find the player's games.
        where: fragment("? @> ?", g.player_ids, type(^[user_id], {:array, Ecto.UUID})),
        where: u.id in ^ids and not is_nil(g.completed_at),
        group_by: u.id,
        select: {u.id, max(g.completed_at)}
    )
    |> Map.new()
  end

  defp changed(ids) do
    for id <- ids do
      Phoenix.PubSub.broadcast(PidroServer.PubSub, "lobby:updates", {:friends_changed, id})
    end
  end
end
