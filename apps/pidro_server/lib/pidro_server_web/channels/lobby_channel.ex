defmodule PidroServerWeb.LobbyChannel do
  @moduledoc """
  LobbyChannel handles real-time updates for the game lobby.

  The lobby shows available rooms, active games, and player presence.
  All authenticated users can join the lobby channel to see live updates
  when rooms are created, updated, or closed.

  ## Channel Topic

  * `"lobby"` - Global lobby channel

  ## Incoming Events (from client)

  * `"join_room"` - Explicitly claim a seat with `code` and optional `position`.
    Room creation remains a REST operation.

  ## Outgoing Events (to clients)

  * `"room_created"` - New room available: `%{room: room_data}`
  * `"room_updated"` - Room state changed: `%{room: room_data}`
  * `"room_closed"` - Room no longer available: `%{room_code: code}`
  * `"presence_state"` - Presence information (who's online in lobby)
  * `"presence_diff"` - Presence changes
  * `"friends_changed"` - `%{}`; refetch the friends list. Sent to each affected player
  * `"friend_request"` - `%{player: entry, played_together_at: iso8601 | nil}`; sent to
    the player a new request reaches, with the sender's friends-list entry
  * `"friend_accepted"` - `%{player: entry, source: "accept"}`; sent to the player whose
    request was just answered, with the entry of the player who accepted
  * `"seat_invitation"` - A seat held for you, with its host
  * `"seat_invitation_gone"` - `%{code: code, position: position}`; the hold is over

  ## Examples

      # Join the lobby
      channel.join("lobby", {})
        .receive("ok", ({rooms}) => console.log("Current rooms:", rooms))

      # Listen for new rooms
      channel.on("room_created", ({room}) => addRoomToList(room))

      # Listen for room updates
      channel.on("room_updated", ({room}) => updateRoomInList(room))

      # Listen for room closures
      channel.on("room_closed", ({room_code}) => removeRoomFromList(room_code))
  """

  use Phoenix.Channel, log_join: :debug

  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.PresenceAggregator
  alias PidroServer.Games.Room.{Config, Seat}
  alias PidroServerWeb.API.RoomJSON
  alias PidroServerWeb.ErrorContract
  alias PidroServerWeb.Presence
  alias PidroServer.Accounts.Auth
  alias PidroServer.Accounts.User

  @positions %{
    "north" => :north,
    "east" => :east,
    "south" => :south,
    "west" => :west,
    "north_south" => :north_south,
    "east_west" => :east_west
  }

  @doc """
  Joins the lobby channel.

  Any authenticated user can join the lobby. On join:
  - Subscribes to lobby update events via PubSub
  - Tracks user presence in the lobby
  - Returns current list of available rooms
  """
  @impl true
  def join("lobby", _params, socket) do
    # Subscribe to lobby updates
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    user_id = socket.assigns.user_id
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:invitations:#{user_id}")

    # Get current available room list (excludes finished and closed)
    rooms = RoomManager.list_rooms(:available) |> Enum.filter(&RoomManager.visible_in_lobby?/1)

    # Get categorized lobby data for this user
    lobby = RoomManager.list_lobby(user_id)

    # Track presence after join
    send(self(), :after_join)

    {:ok,
     %{
       rooms: serialize_rooms(rooms),
       lobby: serialize_lobby(lobby),
       online_count: PresenceAggregator.get_count()
     }, socket}
  end

  @impl true
  def handle_in("join_room", %{"code" => code} = params, socket) when is_binary(code) do
    position =
      Map.get(@positions, params["position"], if(params["position"], do: :invalid, else: nil))

    with %User{} = user <- Auth.get_user(socket.assigns.user_id),
         {:ok, room, assigned_position} <- RoomManager.join_room(code, user, position) do
      {:reply,
       {:ok, %{room: serialize_room_with_users(room), assigned_position: assigned_position}},
       socket}
    else
      {:error, {:seat_requires_games, min_games, games_played} = reason} ->
        {:reply,
         {:error,
          ErrorContract.add(
            %{
              status: "error",
              reason: "seat_requires_games",
              min_games: min_games,
              games_played: games_played
            },
            reason,
            :action_failed
          )}, socket}

      {:error, reason} ->
        legacy_reason = if is_atom(reason), do: Atom.to_string(reason), else: "action_failed"
        # A room moving between nodes is there, just not yet here.
        code = if reason == :room_moving, do: :game_unavailable, else: reason

        {:reply,
         {:error,
          ErrorContract.add(%{status: "error", reason: legacy_reason}, code, :action_failed)},
         socket}

      nil ->
        {:reply,
         {:error,
          ErrorContract.add(
            %{status: "error", reason: "unauthorized"},
            :unauthorized,
            :action_failed
          )}, socket}
    end
  end

  def handle_in("join_room", _params, socket),
    do:
      {:reply,
       {:error,
        ErrorContract.add(
          %{status: "error", reason: "invalid_room_params"},
          :invalid_room_params,
          :action_failed
        )}, socket}

  @doc """
  Handles internal messages.

  Processes the following events:
  - `:room_created` - New room available
  - `:room_updated` - Room state changed
  - `:room_closed` - Room removed
  - `:online_count_updated` - Online user count changed
  - `:after_join` - Presence tracking after join
  """
  @impl true
  def handle_info(msg, socket)

  def handle_info({:friends_changed, user_id}, socket) do
    if socket.assigns.user_id == user_id, do: push(socket, "friends_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:friend_event, user_id, event, payload}, socket) do
    if socket.assigns.user_id == user_id, do: push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:seat_invitation, user_id, invitation}, socket) do
    if socket.assigns.user_id == user_id and
         not PidroServer.Blocks.blocked?(invitation.host_id, user_id) do
      push(socket, "seat_invitation", RoomManager.seat_invitation_with_host(invitation))
    end

    {:noreply, socket}
  end

  def handle_info({:seat_invitation_gone, user_id, invitation}, socket) do
    if socket.assigns.user_id == user_id, do: push(socket, "seat_invitation_gone", invitation)
    {:noreply, socket}
  end

  def handle_info({:room_created, room}, socket) do
    if RoomManager.visible_in_lobby?(room) do
      serialized = serialize_room_with_users(room)
      category = determine_category(room, socket.assigns.user_id)

      push(socket, "room_created", %{
        room: serialized,
        category: category,
        action: "added"
      })
    end

    {:noreply, socket}
  end

  def handle_info({:room_updated, room}, socket) do
    if RoomManager.visible_in_lobby?(room) do
      serialized = serialize_room_with_users(room)
      category = determine_category(room, socket.assigns.user_id)

      push(socket, "room_updated", %{
        room: serialized,
        category: category,
        action: "updated"
      })
    end

    {:noreply, socket}
  end

  def handle_info({:room_closed, room_code}, socket) do
    push(socket, "room_closed", %{
      room_code: room_code,
      action: "removed"
    })

    {:noreply, socket}
  end

  def handle_info({:online_count_updated, payload}, socket) do
    push(socket, "online_count_updated", payload)
    {:noreply, socket}
  end

  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    {:ok, _} =
      Presence.track(socket, user_id, %{
        online_at: DateTime.utc_now() |> DateTime.to_unix()
      })

    PresenceAggregator.track(user_id, :lobby)

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  ## Private Helpers

  defp serialize_room_with_users(room) do
    user_map = RoomJSON.users_for_rooms([room])
    serialize_room(room, user_map)
  end

  @spec serialize_rooms([RoomManager.Room.t()]) :: [map()]
  defp serialize_rooms(rooms) do
    user_map = RoomJSON.users_for_rooms(rooms)

    Enum.map(rooms, &serialize_room(&1, user_map))
  end

  @spec serialize_room(RoomManager.Room.t(), map()) :: map()
  defp serialize_room(room, user_map) do
    alias PidroServer.Games.Room.Positions

    %{
      code: room.code,
      host_id: room.host_id,
      player_count: Positions.count(room),
      available_positions: RoomManager.available_positions(room),
      max_players: room.max_players,
      status: room.status,
      locked: room.locked,
      created_at: DateTime.to_iso8601(room.created_at),
      config: Config.serialize(room.config),
      seats: serialize_seats(room, user_map)
    }
    |> Map.merge(RoomManager.Room.game_payload(room))
  end

  defp serialize_seats(room, user_map) do
    [:north, :east, :south, :west]
    |> Enum.with_index()
    |> Enum.map(fn {position, index} ->
      seat = Map.get(room.seats, position)
      player_id = room.positions[position]

      player_data =
        if player_id do
          get_player_summary(player_id, user_map, seat)
        else
          nil
        end

      base = %{
        position: position,
        seat_index: index,
        status: if(player_id, do: "occupied", else: "free"),
        player: player_data,
        min_games: 0,
        password: false
      }

      case seat do
        %Seat{} ->
          seat_data =
            room.config |> Config.serialize_seat(seat) |> RoomJSON.with_held_user(user_map)

          Map.merge(base, %{
            min_games: seat_data.min_games,
            password: seat_data.password,
            occupant_type: seat_data.occupant_type,
            lifecycle_status: seat_data.status,
            is_owner: seat_data.is_owner,
            disconnected_at: seat_data.disconnected_at,
            grace_expires_at: seat_data.grace_expires_at,
            has_reservation: seat_data.has_reservation,
            joined_at: seat_data.joined_at
          })
          |> Map.merge(Map.take(seat_data, [:vacated_by, :held_for]))

        nil ->
          base
      end
    end)
  end

  defp serialize_lobby(lobby) do
    rooms =
      [:my_rejoinable, :open_tables, :substitute_needed, :spectatable]
      |> Enum.flat_map(&Map.get(lobby, &1, []))

    users_map = RoomJSON.users_for_rooms(rooms)

    # Serialize all categories with the shared users_map
    %{
      my_rejoinable: Enum.map(lobby.my_rejoinable, &serialize_room(&1, users_map)),
      open_tables: Enum.map(lobby.open_tables, &serialize_room(&1, users_map)),
      substitute_needed: Enum.map(lobby.substitute_needed, &serialize_room(&1, users_map)),
      spectatable: Enum.map(lobby.spectatable, &serialize_room(&1, users_map))
    }
  end

  defp determine_category(room, user_id) do
    case RoomManager.lobby_category(room, user_id) do
      nil -> nil
      category -> Atom.to_string(category)
    end
  end

  defp get_player_summary(player_id, _user_map, %Seat{bot_persona: persona} = seat)
       when is_binary(persona) do
    name = Seat.bot_display_name(persona)
    profile = Seat.serialize(seat).bot_profile

    %{
      id: player_id,
      username: name,
      display_name: name,
      is_bot: true,
      bot_persona: persona,
      bot_profile: profile,
      avatar_url: profile && profile.avatar_url,
      level: nil,
      prestige: nil,
      pin: nil
    }
  end

  defp get_player_summary(player_id, user_map, _seat) do
    case Map.get(user_map, player_id) do
      %User{} = user ->
        %{
          id: user.id,
          username: user.username,
          display_name: user.display_name,
          is_bot: false,
          bot_persona: nil,
          avatar_url: user.avatar_url,
          level: user.level,
          prestige: user.prestige,
          pin: user.pin
        }

      nil ->
        # If user not found in DB, assume it's a bot or dev/test user
        %{
          id: player_id,
          username: "Bot/User #{String.slice(player_id, 0..5)}",
          display_name: nil,
          is_bot: true,
          bot_persona: nil,
          avatar_url: nil,
          level: nil,
          prestige: nil,
          pin: nil
        }
    end
  end
end
