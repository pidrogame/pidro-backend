defmodule PidroServerWeb.API.RoomJSON do
  @moduledoc """
  JSON view module for rendering room data in API responses.

  This module provides functions to serialize room data into JSON format,
  following a JSON:API-like structure with a data wrapper. It handles
  single room responses, room lists, and room creation responses.
  """

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Games.Room.{Config, Positions, Seat}
  alias PidroServerWeb.Serializers.GameStateSerializer

  @doc """
  Renders a single room response.

  Takes a map with a :room key and returns the serialized room data
  wrapped in a data envelope. Optionally includes assigned_position if provided.

  ## Examples

      iex> show(%{room: room})
      %{data: %{room: room_data}}

      iex> show(%{room: room, assigned_position: :north})
      %{data: %{room: room_data, assigned_position: "north"}}
  """
  def show(assigns) do
    data = %{room: host_room(assigns.room, assigns[:current_user])}
    data = maybe_add_assigned_position(data, assigns)
    %{data: data}
  end

  @doc """
  Renders a list of rooms.

  Takes a map with a :rooms key (list) and returns all serialized room data
  wrapped in a data envelope.

  ## Examples

      iex> index(%{rooms: [room1, room2]})
      %{data: %{rooms: [room_data1, room_data2]}}
  """
  def index(%{rooms: rooms}) do
    %{data: %{rooms: serialize_rooms(rooms)}}
  end

  @doc """
  Renders a room created response with the room code.

  Takes a map with a :room key and returns the serialized room data
  including the room code for quick reference, wrapped in a data envelope.

  ## Examples

      iex> created(%{room: room})
      %{data: %{room: room_data, code: "A1B2"}}
  """
  def created(%{room: room} = assigns) do
    %{data: %{room: host_room(room, assigns[:current_user]), code: room.code}}
  end

  # The seat password is the host's to read out; nobody else's payload has it.
  defp host_room(room, current_user) do
    data = room(room, users_for_rooms([room]))

    case {current_user, Map.get(room, :config)} do
      {%{id: id}, %Config{seat_password: password}}
      when id == room.host_id and is_binary(password) ->
        Map.put(data, :seat_password, password)

      _ ->
        data
    end
  end

  @doc """
  Renders categorized lobby data.

  Returns rooms grouped into four categories: my_rejoinable, open_tables,
  substitute_needed, and spectatable. Each category contains serialized room data.
  """
  def lobby(%{lobby: lobby}) do
    rooms =
      lobby.my_rejoinable ++ lobby.open_tables ++ lobby.substitute_needed ++ lobby.spectatable

    users = users_for_rooms(rooms)

    %{
      data: %{
        my_rejoinable: serialize_rooms(lobby.my_rejoinable, users),
        open_tables: serialize_rooms(lobby.open_tables, users),
        substitute_needed: serialize_rooms(lobby.substitute_needed, users),
        spectatable: serialize_rooms(lobby.spectatable, users)
      }
    }
  end

  @doc """
  Renders the game state for a room.

  Takes a map with a :state key and returns the serialized game state
  wrapped in a data envelope. The game state is a complex Elixir struct
  from Pidro.Server that contains all game information.

  ## Examples

      iex> state(%{state: game_state})
      %{data: %{state: serialized_state}}
  """
  def state(%{state: game_state}) do
    %{data: %{state: GameStateSerializer.serialize_public(game_state)}}
  end

  @doc """
  Transforms a Room struct into a JSON-serializable map.

  Serializes all room fields including:
  - code: Unique room code
  - host_id: User ID of the room host
  - positions: Map of positions to player IDs
  - available_positions: List of unoccupied positions
  - player_count: Number of seated players
  - spectator_ids: List of spectator user IDs
  - status: Current room status (:waiting, :ready, :playing, :finished, or :closed)
  - locked: Whether the host has locked the table (R25)
  - max_players: Maximum number of players allowed
  - max_spectators: Maximum number of spectators allowed
  - created_at: Room creation timestamp in ISO8601 format
  - config: The room config (name, bot_difficulty, solo), as `Room.Config.serialize/1` emits it
  """
  def room(%{room: room}), do: room(room)

  def room(room) when is_map(room) do
    room(room, users_for_rooms([room]))
  end

  @doc """
  Adds the same public player names as HTTP rooms to an authoritative
  readiness snapshot, and whether each seat reads typed talk. Only the
  table's own channel sends this, so the lobby never shows who is a minor.
  """
  def readiness(snapshot) do
    held_ids = for {_pos, %{held_for: %{user_id: id}}} <- snapshot.seats, do: id

    users =
      (Map.values(snapshot.positions) ++ held_ids)
      |> Enum.reject(&is_nil/1)
      |> Auth.get_users_map()

    %{
      snapshot
      | seats:
          Map.new(snapshot.seats, fn {position, seat} ->
            reads_typed = User.reads_typed?(seat_user(seat, users))
            {position, seat |> with_player_names(users) |> Map.put(:reads_typed, reads_typed)}
          end)
    }
  end

  defp room(room, users) do
    %{
      code: room.code,
      host_id: room.host_id,
      # New fields for position selection feature
      positions: serialize_positions(room.positions),
      available_positions: PidroServer.Games.RoomManager.available_positions(room),
      player_count: Positions.count(room),
      # Legacy field for backward compatibility - derive from positions
      player_ids: Positions.player_ids(room),
      spectator_ids: room.spectator_ids,
      status: room.status,
      locked: Map.get(room, :locked, false),
      max_players: room.max_players,
      max_spectators: room.max_spectators,
      created_at: DateTime.to_iso8601(room.created_at),
      config: serialize_config(Map.get(room, :config)),
      seats:
        serialize_room_seats(Map.get(room, :seats, %{}), Map.get(room, :config, %Config{}), users)
    }
    |> Map.merge(PidroServer.Games.RoomManager.Room.game_payload(room))
  end

  # Room-shaped maps without a config (invite redeem, tests) serialize the default.
  defp serialize_config(%Config{} = config), do: Config.serialize(config)
  defp serialize_config(nil), do: Config.serialize(%Config{})

  defp serialize_rooms(rooms), do: serialize_rooms(rooms, users_for_rooms(rooms))
  defp serialize_rooms(rooms, users), do: Enum.map(rooms, &room(&1, users))

  @doc "Fetches occupants and held users together for room projections."
  def users_for_rooms(rooms) do
    rooms
    |> Enum.flat_map(&(Positions.player_ids(&1) ++ Map.values(&1.config.seat_holds)))
    |> Enum.uniq()
    |> Auth.get_users_map()
  end

  defp serialize_room_seats(seats, _config, _users) when map_size(seats) == 0, do: %{}

  defp serialize_room_seats(seats, config, users) do
    Map.new(seats, fn {position, seat} ->
      {position, config |> Config.serialize_seat(seat) |> with_player_names(users)}
    end)
  end

  defp with_player_names(seat, users) do
    user = seat_user(seat, users)

    seat
    |> Map.put(:is_bot, bot_seat?(seat))
    |> Map.put(:username, seat_username(seat, user))
    |> Map.put(:display_name, seat_display_name(seat, user))
    |> Map.put(:avatar_url, if(user, do: user.avatar_url, else: bot_avatar(seat)))
    |> Map.put(:level, if(user, do: user.level, else: nil))
    |> Map.put(:prestige, if(user, do: user.prestige, else: nil))
    |> Map.put(:pin, if(user, do: user.pin, else: nil))
    |> with_held_user(users)
  end

  @doc "Adds public profile fields to a serialized friend hold."
  def with_held_user(%{held_for: %{user_id: id}} = seat, users) do
    user = users[id]

    %{
      seat
      | held_for: %{
          user_id: id,
          display_name: user && (user.display_name || user.username),
          avatar_url: user && user.avatar_url
        }
    }
  end

  def with_held_user(seat, _users), do: seat

  # The user row behind a human seat; nil for bots, vacant seats and ids that
  # resolve to nobody (a deleted account, R25).
  defp seat_user(%{occupant_type: :bot}, _users), do: nil
  defp seat_user(%{user_id: "bot_" <> _}, _users), do: nil

  defp seat_user(%{user_id: user_id}, users) when is_binary(user_id),
    do: Map.get(users, user_id)

  defp seat_user(_seat, _users), do: nil

  defp seat_username(seat, nil), do: bot_name(seat)
  defp seat_username(_seat, user), do: user.username

  defp seat_display_name(seat, nil), do: bot_name(seat)
  defp seat_display_name(_seat, user), do: user.display_name

  defp bot_name(%{bot_persona: persona}) when is_binary(persona),
    do: Seat.bot_display_name(persona)

  defp bot_name(seat), do: if(bot_seat?(seat), do: "Bot", else: nil)

  defp bot_avatar(%{bot_profile: %{avatar_url: url}}), do: url
  defp bot_avatar(_seat), do: nil

  defp bot_seat?(%{occupant_type: :bot}), do: true
  defp bot_seat?(%{user_id: "bot_" <> _}), do: true
  defp bot_seat?(_seat), do: false

  @doc false
  defp serialize_positions(positions) do
    Map.new(positions, fn {pos, player_id} ->
      {pos, player_id}
    end)
  end

  @doc false
  defp maybe_add_assigned_position(data, %{assigned_position: pos}) when not is_nil(pos) do
    Map.put(data, :assigned_position, pos)
  end

  defp maybe_add_assigned_position(data, _), do: data
end
