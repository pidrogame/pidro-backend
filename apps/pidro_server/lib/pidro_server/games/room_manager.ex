defmodule PidroServer.Games.RoomManager do
  @moduledoc """
  GenServer for managing game rooms in the Pidro application.

  The RoomManager handles the lifecycle of game rooms, including:
  - Creating new rooms with unique codes
  - Managing player joins and leaves
  - Starting full tables after every human confirms readiness on a live channel
  - Broadcasting room and lobby updates via PubSub
  - Tracking player-to-room mappings to prevent duplicate room membership

  ## Room Lifecycle

  1. **Creation**: A host creates a room with a unique 4-character alphanumeric code
  2. **Waiting**: Players join and confirm readiness for the current roster epoch
  3. **Ready**: A full table with all humans ready transitions through `:ready` to `:playing`
  4. **Closed**: Room closes when host leaves or all players leave

  ## PubSub Events

  The RoomManager broadcasts events on three topics:
  - `lobby:updates` - Notifies all clients about room list changes
  - `room:<room_code>` - Notifies players in a specific room about room changes
  - `game:<room_code>` - Seat events for game channels: the disconnect cascade,
    substitutes, `invite_redeemed`, `seat_moved`, `kicked`, `readiness_updated`
    and `seat_invitation_declined`

  ## Examples

      # Create a new room
      {:ok, room} = RoomManager.create_room("user123", %{name: "Fun Game"})

      # Join an existing room
      {:ok, room} = RoomManager.join_room("ABCD", "user456")

      # Leave a room
      :ok = RoomManager.leave_room("user123")

      # List all waiting rooms
      rooms = RoomManager.list_rooms(:waiting)

      # Get specific room details
      {:ok, room} = RoomManager.get_room("ABCD")
  """

  use GenServer
  require Logger

  alias Pidro.Core.{Chance, SeatView}
  alias Pidro.Game.{Engine, Play}
  alias PidroServer.Accounts.User
  alias PidroServer.Games.Bots.{BotBrain, BotManager, SubstituteBot, TimeoutStrategy}
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomCodes, TurnTimer}
  alias PidroServer.Games.Room.Config
  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Stats

  @max_players 4
  # Two engine calls must finish well before the public caller's 5-second timeout.
  @player_action_call_timeout_ms 250

  # Room struct representing a game room
  defmodule Room do
    @moduledoc """
    Struct representing a game room.

    ## Fields

    - `:id` - Stable UUID assigned at creation; invites bind to it so a reused code cannot seat a stranger
    - `:code` - Unique 4-character alphanumeric room code
    - `:host_id` - User ID of the room host (creator)
    - `:locked` - When true the host has closed the table to joins and invite claims (reclaims still work)
    - `:kicked_ids` - User IDs the host kicked; they cannot join, claim or substitute into this room again
    - `:invite_live_until` - Latest `expires_at` of the room's active invites, or nil; drives only the sweep
    - `:positions` - Map of positions to player IDs (%{north: "user1", east: nil, ...}) - SINGLE SOURCE OF TRUTH
    - `:spectator_ids` - List of user IDs currently spectating the room
    - `:status` - Current room status (`:waiting`, `:ready`, `:playing`, `:finished`, or `:closed`)
    - `:max_players` - Maximum number of players (default: 4)
    - `:max_spectators` - Maximum number of spectators (default: 10)
    - `:created_at` - DateTime when the room was created
    - `:config` - The `Room.Config` set at creation: name, requested bot difficulty and whether the table is solo. Never changes for the life of the room
    - `:phase_timers` - Map of position to timer reference for the disconnect cascade (%{position => reference()})
    - `:post_game_summaries` - The last game's `%{user_id => summary}`, kept while `:finished` so a rejoin sees it

    ## Derived Data

    DO NOT store player_ids separately. Use `Positions.player_ids(room)` to derive the list.
    """

    @type position :: :north | :east | :south | :west
    @type positions_map :: %{position() => String.t() | nil}
    @type status :: :waiting | :ready | :playing | :finished | :closed
    @type t :: %__MODULE__{
            id: Ecto.UUID.t() | nil,
            code: String.t(),
            host_id: String.t() | nil,
            locked: boolean(),
            kicked_ids: [String.t()],
            invite_live_until: DateTime.t() | nil,
            positions: positions_map(),
            spectator_ids: [String.t()],
            status: status(),
            max_players: integer(),
            max_spectators: integer(),
            created_at: DateTime.t(),
            config: Config.t(),
            pace: :quick | :own,
            seat_hold_started_at: %{optional(Positions.position()) => DateTime.t()},
            phase_timers: %{Positions.position() => reference()},
            seats: map(),
            bot_personas: [Seat.bot_persona()],
            last_activity: DateTime.t(),
            turn_timer: TurnTimer.t() | nil,
            consecutive_timeouts: %{optional(Positions.position()) => non_neg_integer()},
            last_hand_number: non_neg_integer() | nil,
            game: map() | nil,
            ready_epoch: non_neg_integer(),
            snapshot_revision: non_neg_integer(),
            ready_player_ids: MapSet.t(String.t()),
            seat_lifecycle_revision: non_neg_integer(),
            game_number: non_neg_integer(),
            game_started_at: DateTime.t() | nil,
            post_game_summaries: %{optional(String.t()) => map()}
          }

    defstruct [
      :id,
      :code,
      :host_id,
      :status,
      :max_players,
      :created_at,
      :last_activity,
      config: %Config{},
      pace: :quick,
      seat_hold_started_at: %{},
      locked: false,
      kicked_ids: [],
      invite_live_until: nil,
      positions: %{north: nil, east: nil, south: nil, west: nil},
      spectator_ids: [],
      max_spectators: 10,
      phase_timers: %{},
      seats: %{},
      bot_personas: Seat.bot_personas(),
      turn_timer: nil,
      consecutive_timeouts: %{},
      last_hand_number: nil,
      game: nil,
      ready_epoch: 0,
      snapshot_revision: 0,
      ready_player_ids: MapSet.new(),
      seat_lifecycle_revision: 0,
      # Games started in this room. A rematch starts game 2, 3, ... in place.
      game_number: 0,
      game_started_at: nil,
      post_game_summaries: %{}
    ]

    @doc "Public game progress, omitted outside a playing room."
    @spec game_payload(map()) :: map()
    def game_payload(%{status: :playing, game: game}) when is_map(game), do: %{game: game}
    def game_payload(_room), do: %{}
  end

  # Internal state struct
  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            rooms: %{String.t() => Room.t()},
            player_rooms: %{String.t() => String.t()},
            spectator_rooms: %{String.t() => String.t()},
            subscribed_game_topics: MapSet.t(String.t()),
            channel_pids: %{{String.t(), any()} => MapSet.t(pid())},
            channel_monitors: %{reference() => {String.t(), any(), pid()}},
            spectator_monitors: %{reference() => {String.t(), any(), pid()}},
            spectator_timers: %{{String.t(), any()} => reference()},
            game_snapshot_cursors: %{String.t() => {String.t(), non_neg_integer()}},
            active_game_instances: %{String.t() => String.t()},
            finished_absences: %{{String.t(), any()} => reference()}
          }

    defstruct rooms: %{},
              player_rooms: %{},
              spectator_rooms: %{},
              subscribed_game_topics: MapSet.new(),
              channel_pids: %{},
              channel_monitors: %{},
              spectator_monitors: %{},
              spectator_timers: %{},
              game_snapshot_cursors: %{},
              active_game_instances: %{},
              # One token per player absent from a finished room; see `note_finished_absence/3`.
              finished_absences: %{}
  end

  ## Client API

  @doc """
  Starts the RoomManager GenServer.

  ## Options

  Standard GenServer options can be passed.

  ## Examples

      {:ok, pid} = RoomManager.start_link([])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @doc """
  Creates a new game room.

  The creator becomes the host of the room. A unique 4-character alphanumeric
  room code is generated. The room starts in `:waiting` status.

  ## Parameters

  - `host_id` - User ID of the room creator
  - `config_or_attrs` - A `Room.Config`, or the attributes `Room.Config.new/1`
    accepts (`name`, `bot_difficulty`, `solo`) as a map or keyword list.
    Defaults to no name, `:basic` difficulty, not solo.
  - `opts` - Internal options: `:seed` fixes the room's bot crew order.
    Otherwise a fresh seed is drawn. Rematches keep the existing crew and seats.

  The config is validated here, in the caller's process, before the GenServer
  is reached: a rejected request never runs the stale-room eviction that room
  creation performs first.

  ## Returns

  - `{:ok, room}` - Successfully created room
  - `{:error, {:invalid_room_params, errors}}` - An attribute is unknown or invalid; no room is created
  - `{:error, :already_in_room}` - Host is already in another room
  - `{:error, :room_code_exhausted}` - No free code was found within the retry bound

  ## Examples

      {:ok, room} = RoomManager.create_room("user123", %{name: "Fun Game"})
      room.code #=> "A1B2"
      room.status #=> :waiting
  """
  @spec create_room(String.t(), Config.t() | map() | keyword(), keyword()) ::
          {:ok, Room.t()}
          | {:error,
             :already_in_room
             | :room_code_exhausted
             | :user_not_found
             | :profile_unavailable
             | Config.errors()}
  def create_room(host_id, config_or_attrs \\ %{}, opts \\ []) do
    with {:ok, %Config{} = config} <- Config.new(config_or_attrs),
         :ok <- validate_hold_users(config.seat_holds, [host_id]),
         :ok <- ensure_unblocked_holds(host_id, Map.values(config.seat_holds)) do
      seed =
        Keyword.get_lazy(opts, :seed, fn ->
          :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned()
        end)

      GenServer.call(__MODULE__, {:create_room, host_id, config, seed})
    end
  end

  @doc "Sets or releases a friend hold on a vacant waiting-room seat; host only."
  @spec set_seat_hold(String.t(), String.t(), Positions.position(), String.t() | nil) ::
          {:ok, Room.t()} | {:error, term()}
  def set_seat_hold(code, host_id, position, user_id) do
    with :ok <- validate_hold_users(if(user_id, do: %{position => user_id}, else: %{}), []) do
      GenServer.call(
        __MODULE__,
        {:set_seat_hold, String.upcase(code), host_id, position, user_id}
      )
    end
  end

  @doc """
  Makes a seat of a waiting room what the host picked for it (see
  `Config.put_seat/3`); host only. A human's seat never changes. A bot leaves
  the seat unless `entry` is `:bot`. A `:bot` entry seats the bot in the same
  call; starting its process is the caller's next step, and the process takes
  the seat it finds waiting for it.
  """
  @spec set_seat(String.t(), String.t(), Positions.position(), Config.seat_entry()) ::
          {:ok, Room.t()} | {:error, term()}
  def set_seat(code, host_id, position, entry) do
    holds =
      case entry do
        {:held, user_id} -> %{position => user_id}
        _ -> %{}
      end

    with :ok <- validate_hold_users(holds, []),
         {:ok, room, bot_pid} <-
           GenServer.call(__MODULE__, {:set_seat, String.upcase(code), host_id, position, entry}) do
      # Stopped here, not in the room manager: the bot manager may be waiting
      # on the room manager for a bot it is starting.
      if bot_pid && BotManager.bot_pid(room.code, position) == bot_pid,
        do: BotManager.stop_bot(room.code, position)

      {:ok, room}
    end
  end

  @doc """
  The invited player answers Not now: releases their hold at `position` like a
  host release and tells the room `{:seat_invitation_declined, %{position,
  user_id, reason: "not_now"}}` on `game:<code>`. Anyone else, or no hold,
  answers `{:error, :invitation_gone}`.
  """
  @spec decline_seat_hold(String.t(), String.t(), Positions.position()) ::
          {:ok, Room.t()} | {:error, :invitation_gone}
  def decline_seat_hold(code, user_id, position) do
    GenServer.call(__MODULE__, {:decline_seat_hold, String.upcase(code), user_id, position})
  end

  @doc "Pending seat invitations derived from live waiting-room holds."
  @spec seat_invitations(String.t()) :: [map()]
  def seat_invitations(user_id) do
    __MODULE__
    |> GenServer.call({:seat_invitations, user_id})
    |> Enum.reject(&PidroServer.Blocks.blocked?(&1.host_id, user_id))
    |> Enum.map(&seat_invitation_with_host/1)
  end

  @doc "Resolves a seat invitation's host outside the room manager, without presence."
  @spec seat_invitation_with_host(map()) :: map()
  def seat_invitation_with_host(invitation) do
    Map.put(invitation, :host, public_user(invitation.host_id))
  end

  @doc "A user's public identity for invitation events, resolved outside the room manager."
  @spec public_user(String.t()) :: map()
  def public_user(user_id) do
    user = PidroServer.Accounts.Auth.get_users_map([user_id])[user_id]

    %{
      user_id: user_id,
      display_name: user && User.public_name(user),
      avatar_url: user && user.avatar_url
    }
  end

  defp validate_hold_users(holds, seated_ids) do
    ids = Map.values(holds)
    users = PidroServer.Accounts.Auth.get_users_map(ids)

    if length(Enum.uniq(ids)) == length(ids) and
         Enum.all?(ids, &(Map.has_key?(users, &1) and &1 not in seated_ids)),
       do: :ok,
       else:
         {:error,
          {:invalid_room_params,
           [
             %{
               field: "seats",
               message: "holds require distinct existing users who are not seated"
             }
           ]}}
  end

  @doc """
  Joins an existing room.

  A player can only be in one room at a time. Filling the table does not start
  it: every human must confirm readiness through a registered live channel
  for the current roster epoch. Trusted bot seats count as ready.

  In a playing room this explicit command claims an owner-opened substitute
  seat (auto-assigned). A successful join ends the player's spectator membership;
  channel attachment alone never claims a seat.

  ## Parameters

  - `room_code` - The unique room code (case-insensitive)
  - `player` - The authenticated user, or a trusted internal user ID
  - `position` - Optional position preference (`:north`, `:east`, `:south`, `:west`, `:north_south`, `:east_west`, or `nil` for auto)

  ## Returns

  - `{:ok, room, assigned_position}` - Successfully joined room with assigned position
  - `{:error, :room_not_found}` - Room code doesn't exist
  - `{:error, :room_full}` - Room already has 4 players
  - `{:error, :already_in_room}` - Player is already in another room
  - `{:error, :seat_taken}` - Requested specific seat is already occupied
  - `{:error, :team_full}` - Requested team is fully occupied
  - `{:error, :invalid_position}` - Invalid position parameter
  - `{:error, :room_not_available}` - Room is not `:waiting`, `:ready`, or `:playing`
  - `{:error, :no_vacant_seat}` - Playing room has no owner-opened seat
  - `{:error, :already_seated}` - Player already occupies a seat in this room
  - `{:error, :table_locked}` - The host locked the table (see `set_locked/3`)
  - `{:error, :kicked}` - The host kicked this player from the room (see `kick_player/3`)
  - `{:error, :account_required}` - A guest tried to claim an ordinary open seat
  - `{:error, :seat_requires_password}` - The seat needs the room's password and
    `password` is missing or wrong

  ## Examples

      {:ok, room, :north} = RoomManager.join_room("A1B2", "user456", :north)
      {:ok, room, :south} = RoomManager.join_room("A1B2", "user789", :north_south)
      {:ok, room, :east} = RoomManager.join_room("A1B2", "user999")
  """
  @spec join_room(String.t(), User.t() | String.t(), Positions.choice()) ::
          {:ok, Room.t(), Positions.position()}
          | {:error,
             :room_not_found
             | :room_full
             | :already_in_room
             | :seat_taken
             | :team_full
             | :invalid_position
             | :room_not_available
             | :no_vacant_seat
             | :already_seated
             | :table_locked
             | :kicked
             | :account_required
             | :profile_unavailable
             | :seat_requires_password
             | {:seat_requires_games, pos_integer(), non_neg_integer()}}
  def join_room(room_code, player, position \\ nil, password \\ nil) do
    {player_id, guest?} = admission_identity(player)

    # The password travels as a closure, so a crash report, a call timeout or an
    # inspect of this call shows a function, never the digits.
    secret = if password, do: fn -> password end

    GenServer.call(
      __MODULE__,
      {:join_room, String.upcase(room_code), player_id, position, guest?, secret}
    )
  end

  @doc "Trusted server-only bot seating; unlike join_room/3 this records a bot occupant."
  def join_bot(room_code, bot_id, bot_pid, position) when is_pid(bot_pid) do
    GenServer.call(__MODULE__, {:join_bot, String.upcase(room_code), bot_id, bot_pid, position})
  end

  @doc """
  Removes a player from their current room.

  If the player is the host, the room is closed and all players are removed.
  If the room becomes empty, it is automatically deleted.

  ## Parameters

  - `player_id` - User ID of the leaving player

  ## Returns

  - `:ok` - Successfully left room
  - `{:error, :not_in_room}` - Player is not in any room

  ## Examples

      :ok = RoomManager.leave_room("user123")
  """
  @spec leave_room(String.t()) :: :ok | {:error, :not_in_room}
  def leave_room(player_id) do
    GenServer.call(__MODULE__, {:leave_room, player_id})
  end

  @doc """
  Removes a player from `room_code`, only if that is the room they are in.

  A leave that names a room the player has since left does nothing, so it
  cannot close the room they are in now. Otherwise it behaves as `leave_room/1`.

  ## Returns

  - `:ok` - Successfully left room
  - `{:error, :not_in_room}` - Player is not in `room_code`
  """
  @spec leave_room(String.t(), String.t()) :: :ok | {:error, :not_in_room}
  def leave_room(room_code, player_id) do
    GenServer.call(__MODULE__, {:leave_room, String.upcase(room_code), player_id})
  end

  @doc """
  Lists all rooms, optionally filtered by status.

  ## Parameters

  - `filter` - Optional filter (`:all`, `:waiting`, `:ready`, `:playing`, `:available`). Defaults to `:all`.
    - `:available` returns all rooms except `:finished` and `:closed` (useful for lobby)

  ## Returns

  List of rooms matching the filter criteria.

  ## Examples

      # List all rooms
      all_rooms = RoomManager.list_rooms()

      # List only waiting rooms
      waiting_rooms = RoomManager.list_rooms(:waiting)

      # List available rooms (waiting, ready, or playing)
      available_rooms = RoomManager.list_rooms(:available)
  """
  @spec list_rooms(:all | :waiting | :ready | :playing | :available) :: [Room.t()]
  def list_rooms(filter \\ :all) do
    GenServer.call(__MODULE__, {:list_rooms, filter})
  end

  @doc "Notifies every RoomManager node that user identity metadata changed."
  def identity_changed(user_id) do
    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "room_manager:identity",
      {:identity_changed, user_id}
    )
  end

  @doc """
  Returns true when the room represents a single-player table.

  Reads the solo fact stored on the room's config at creation. A room struct
  built without one carries the default config, which is not solo.
  """
  @spec single_player_room?(Room.t()) :: boolean()
  def single_player_room?(%Room{config: %Config{solo: solo}}), do: solo
  def single_player_room?(%Room{}), do: false

  @doc """
  Returns true when the room should appear in lobby browsing surfaces.
  """
  @spec visible_in_lobby?(Room.t()) :: boolean()
  def visible_in_lobby?(%Room{} = room), do: not single_player_room?(room)

  @doc """
  Returns categorized lobby data for the given user.

  ## Categories

  - `:my_rejoinable` - Playing rooms where the user has a reserved seat (can reclaim)
  - `:open_tables` - Waiting rooms with vacant seats
  - `:substitute_needed` - Playing rooms with vacant seats opened by owner
  - `:spectatable` - Playing rooms with spectator capacity remaining

  Rooms with zero connected humans appear in no category.

  ## Parameters

  - `user_id` - The user's ID (can be nil for anonymous browsing)

  ## Returns

  A map with four category keys, each containing a list of room structs.

  ## Examples

      lobby = RoomManager.list_lobby("user-123")
      lobby.my_rejoinable  # rooms where user can reclaim their seat
      lobby.open_tables    # waiting rooms to join
  """
  @spec list_lobby(String.t() | nil) :: %{
          my_rejoinable: [Room.t()],
          open_tables: [Room.t()],
          substitute_needed: [Room.t()],
          spectatable: [Room.t()]
        }
  def list_lobby(user_id \\ nil) do
    GenServer.call(__MODULE__, {:list_lobby, user_id})
  end

  @doc """
  Gets details of a specific room.

  ## Parameters

  - `room_code` - The unique room code (case-insensitive)

  ## Returns

  - `{:ok, room}` - Room details
  - `{:error, :room_not_found}` - Room doesn't exist

  ## Examples

      {:ok, room} = RoomManager.get_room("A1B2")
  """
  @spec get_room(String.t()) :: {:ok, Room.t()} | {:error, :room_not_found}
  def get_room(room_code) do
    GenServer.call(__MODULE__, {:get_room, String.upcase(room_code)})
  end

  @doc "Publicly claimable seats, shared by REST and lobby snapshots. Bots are not vacancies."
  @spec available_positions(Room.t()) :: [Positions.position()]
  def available_positions(%Room{locked: false, status: status, seats: seats} = room)
      when status in [:waiting, :ready, :playing] do
    Enum.filter(Positions.available(room), fn position ->
      match?(%Seat{occupant_type: :vacant}, seats[position])
    end)
  end

  def available_positions(%Room{}), do: []

  @doc """
  The seat `user_id` takes at `friend_id`'s table, and whether it makes them the
  friend's partner: the partner seat when it is open to them, else the first
  open seat they may take, or `nil`. A seat held for someone else, a password
  seat, or one whose games requirement `games_played` misses is not open to
  them; as in `join_room/3`, a substitute seat at a playing table asks for
  neither password nor games. Who may join at all (a locked table, a kick, a
  block) stays with `join_room/3`.
  """
  @spec friend_seat(Room.t(), String.t(), String.t(), non_neg_integer()) ::
          {Positions.position(), :partner | :opponent} | nil
  def friend_seat(%Room{} = room, user_id, friend_id, games_played) do
    partner = Positions.partner(Seat.position_of(room.seats, friend_id))

    open =
      Enum.filter([:north, :east, :south, :west], &open_to?(room, &1, user_id, games_played))

    cond do
      partner == nil or room.status not in [:waiting, :ready, :playing] -> nil
      Positions.has_player?(room, user_id) -> nil
      partner in open -> {partner, :partner}
      open != [] -> {hd(open), :opponent}
      true -> nil
    end
  end

  # At a playing table any vacant seat takes a substitute, as join_room/3 does;
  # its old player may still be in `positions` after a permanent bot.
  defp open_to?(%Room{status: :playing} = room, position, _user_id, _games_played),
    do: match?(%Seat{occupant_type: :vacant}, room.seats[position])

  # Before play: free, not held for someone else, no password to give, and
  # enough games. A seat held for the player asks for neither.
  defp open_to?(%Room{config: config} = room, position, user_id, games_played) do
    held_for_you? = config.seat_holds[position] == user_id

    room.positions[position] == nil and
      match?(%Seat{occupant_type: :vacant}, room.seats[position]) and
      config.seat_holds[position] in [nil, user_id] and
      Config.check_password(config, position, user_id, nil) == :ok and
      (held_for_you? or games_played >= Map.get(config.seat_requirements, position, 0))
  end

  @doc """
  Updates the status of a room.

  ## Parameters

  - `room_code` - The unique room code
  - `status` - New status (`:waiting`, `:ready`, `:playing`, `:finished`, or `:closed`)

  ## Returns

  - `:ok` - Status updated successfully
  - `{:error, :room_not_found}` - Room doesn't exist

  ## Examples

      :ok = RoomManager.update_room_status("A1B2", :playing)
  """
  @spec update_room_status(String.t(), Room.status()) :: :ok | {:error, :room_not_found}
  def update_room_status(room_code, status) do
    GenServer.call(__MODULE__, {:update_room_status, String.upcase(room_code), status})
  end

  @doc """
  Closes a room and removes it from the room list.

  ## Parameters

  - `room_code` - The unique room code

  ## Returns

  - `:ok` - Room closed successfully
  - `{:error, :room_not_found}` - Room doesn't exist

  ## Examples

      :ok = RoomManager.close_room("A1B2")
  """
  @spec close_room(String.t()) :: :ok | {:error, :room_not_found}
  def close_room(room_code) do
    GenServer.call(__MODULE__, {:close_room, String.upcase(room_code)})
  end

  @doc """
  Joins a room as a spectator.

  Spectators can only join rooms that are currently `:playing` or `:finished`.
  They can watch the game but cannot participate. Repeating Watch for the same
  room succeeds without adding membership. Unattached/disconnected watches have
  a bounded grace period; see `docs/spectator-lifecycle.md`.

  ## Parameters

  - `room_code` - The unique room code (case-insensitive)
  - `spectator_id` - User ID of the spectator

  ## Returns

  - `{:ok, room}` - Successfully joined as spectator
  - `{:error, :room_not_found}` - Room code doesn't exist
  - `{:error, :room_not_available_for_spectators}` - Room is not playing or finished
  - `{:error, :spectators_full}` - Maximum spectators reached
  - `{:error, :already_spectating}` - User is already spectating another room
  - `{:error, :already_in_room}` - User is a player in another room

  ## Examples

      {:ok, room} = RoomManager.join_spectator_room("A1B2", "user789")
  """
  @spec join_spectator_room(String.t(), String.t()) ::
          {:ok, Room.t()}
          | {:error,
             :room_not_found
             | :room_not_available_for_spectators
             | :spectators_full
             | :already_spectating
             | :already_in_room}
  def join_spectator_room(room_code, spectator_id) do
    GenServer.call(__MODULE__, {:join_spectator_room, String.upcase(room_code), spectator_id})
  end

  @doc """
  Removes a spectator from a room.

  ## Parameters

  - `spectator_id` - User ID of the spectator

  ## Returns

  - `:ok` - Successfully left room
  - `{:error, :not_spectating}` - User is not spectating any room

  ## Examples

      :ok = RoomManager.leave_spectator("user789")
  """
  @spec leave_spectator(String.t()) :: :ok | {:error, :not_spectating}
  def leave_spectator(spectator_id) do
    GenServer.call(__MODULE__, {:leave_spectator, nil, spectator_id})
  end

  @doc "Removes a watch only in the specified room; stale requests cannot unwatch another room."
  def leave_spectator(room_code, spectator_id) do
    GenServer.call(__MODULE__, {:leave_spectator, String.upcase(room_code), spectator_id})
  end

  @doc false
  def register_spectator_channel(room_code, user_id, pid) do
    GenServer.call(
      __MODULE__,
      {:register_spectator_channel, String.upcase(room_code), user_id, pid}
    )
  end

  @doc false
  def unregister_spectator_channel(room_code, user_id, pid) do
    GenServer.call(
      __MODULE__,
      {:unregister_spectator_channel, String.upcase(room_code), user_id, pid}
    )
  end

  @doc """
  Checks if a user is a spectator in a specific room.

  ## Parameters

  - `room_code` - The unique room code
  - `user_id` - User ID to check

  ## Returns

  - `true` - User is spectating the room
  - `false` - User is not spectating the room

  ## Examples

      is_spectator = RoomManager.is_spectator?("A1B2", "user789")
  """
  @spec is_spectator?(String.t(), String.t()) :: boolean()
  def is_spectator?(room_code, user_id) do
    GenServer.call(__MODULE__, {:is_spectator, String.upcase(room_code), user_id})
  end

  @doc """
  Dev-only function to directly set a position without join validation.

  Used by dev UI to populate test scenarios with specific players.
  Allows position changes at any time (waiting, ready, playing, finished).
  Set user_id to nil to clear a seat.

  ## Parameters

  - `room_code` - The unique room code
  - `position` - Position to set (:north, :east, :south, :west)
  - `user_id` - User ID to assign, or nil to clear the seat

  ## Returns

  - `{:ok, room}` - Successfully updated position
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :invalid_position}` - Invalid position atom

  ## Examples

      {:ok, room} = RoomManager.dev_set_position("A1B2", :north, "user123")
      {:ok, room} = RoomManager.dev_set_position("A1B2", :south, nil)
  """
  @spec dev_set_position(String.t(), Positions.position(), String.t() | nil) ::
          {:ok, Room.t()} | {:error, :room_not_found | :invalid_position}
  def dev_set_position(room_code, position, user_id)
      when position in [:north, :east, :south, :west] do
    GenServer.call(__MODULE__, {:dev_set_position, String.upcase(room_code), position, user_id})
  end

  def dev_set_position(_room_code, _position, _user_id) do
    {:error, :invalid_position}
  end

  @doc """
  Handles a player disconnect and starts the reconnection grace period.

  When a player disconnects during a multiplayer :playing game, the seat-based
  disconnect cascade is started (hiccup -> grace -> permanent bot). The player
  can reconnect during the hiccup or grace phases to reclaim their seat. A
  solo game's only human seat is held without a deadline until they reconnect.

  In a `:waiting` or `:ready` room the seat is held instead: it becomes
  `:reconnecting` with no timer and no bot, the room cannot start until the
  player reclaims it through `handle_player_reconnect/2`, and the seat is
  vacated only when the player sits down elsewhere (the host's held seat
  closes the room) or the host kicks it.

  ## Parameters

  - `room_code` - The unique room code
  - `user_id` - User ID of the disconnected player

  ## Returns

  - `:ok` - Disconnect tracked successfully
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :player_not_in_room}` - Player is not in this room

  ## Examples

      :ok = RoomManager.handle_player_disconnect("A1B2", "user123")
  """
  @spec handle_player_disconnect(String.t(), String.t()) ::
          :ok | {:error, :room_not_found | :player_not_in_room}
  def handle_player_disconnect(room_code, user_id) do
    GenServer.call(__MODULE__, {:player_disconnect, String.upcase(room_code), user_id})
  end

  @doc """
  Handles a player reconnection within the grace period.

  Supports all three phases of the disconnect cascade:
  - Phase 1 (Hiccup): Seat is `:reconnecting` — cancels timer, reclaims seat
  - Phase 2 (Grace): Seat is `:bot_substitute` with `reserved_for` — terminates bot, reclaims seat
  - Phase 3 (Gone): Seat is `:bot_substitute` without `reserved_for` — rejects with `:seat_permanently_filled`

  A held seat in a `:waiting` room (see `handle_player_disconnect/2`) is
  reclaimed the same way; when the table is full and no other seat is held,
  the game starts and the returned room is already `:playing`.

  ## Parameters

  - `room_code` - The unique room code
  - `user_id` - User ID of the reconnecting player

  ## Returns

  - `{:ok, room}` - Successfully reconnected
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :player_not_disconnected}` - Player was not marked as disconnected
  - `{:error, :grace_period_expired}` - Grace period has expired (player already removed)
  - `{:error, :seat_permanently_filled}` - Bot is permanent, player must return to lobby

  ## Examples

      {:ok, room} = RoomManager.handle_player_reconnect("A1B2", "user123")
  """
  @spec handle_player_reconnect(String.t(), String.t()) ::
          {:ok, Room.t()}
          | {:error,
             :room_not_found
             | :player_not_disconnected
             | :grace_period_expired
             | :seat_permanently_filled}
  def handle_player_reconnect(room_code, user_id) do
    GenServer.call(__MODULE__, {:player_reconnect, String.upcase(room_code), user_id})
  end

  @doc """
  Opens a bot-substitute seat for a human substitute to join.

  Only the room owner can open seats. The target seat must be a `:bot_substitute`
  in a `:playing` room. The bot is terminated and the seat becomes vacant,
  appearing in the lobby's `substitute_needed` category.

  ## Parameters

  - `room_code` - The unique room code
  - `position` - The seat position to open (`:north`, `:east`, `:south`, `:west`)
  - `requesting_user_id` - User ID of the requester (must be the owner)

  ## Returns

  - `{:ok, room}` - Seat opened successfully
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :not_owner}` - Requester is not the room owner
  - `{:error, :room_not_playing}` - Room is not in `:playing` status
  - `{:error, :seat_not_bot_substitute}` - Seat is not a bot substitute

  ## Examples

      {:ok, room} = RoomManager.open_seat("A1B2", :east, "owner-user-id")
  """
  @spec open_seat(String.t(), Positions.position(), String.t(), String.t() | nil) ::
          {:ok, Room.t()}
          | {:error, :room_not_found | :not_owner | :room_not_playing | :seat_not_bot_substitute}
  def open_seat(room_code, position, requesting_user_id, decision_id \\ nil) do
    GenServer.call(
      __MODULE__,
      {:open_seat, String.upcase(room_code), position, requesting_user_id, decision_id}
    )
  end

  @doc "Returns the authoritative, versioned four-seat lifecycle snapshot."
  @spec get_seat_lifecycle(String.t()) :: {:ok, map()} | {:error, :room_not_found}
  def get_seat_lifecycle(room_code) do
    case GenServer.call(__MODULE__, {:get_seat_lifecycle, String.upcase(room_code)}) do
      {:ok, snapshot} -> {:ok, PidroServer.Games.SeatLifecycle.with_names(snapshot)}
      error -> error
    end
  end

  @doc "Resolves a departure decision by keeping its bot, for all clients and future owners."
  def keep_bot(room_code, position, requesting_user_id, decision_id) do
    GenServer.call(
      __MODULE__,
      {:keep_bot, String.upcase(room_code), position, requesting_user_id, decision_id}
    )
  end

  @doc """
  Closes a vacant seat by spawning a new bot to fill it.

  Only the room owner can close seats. The target seat must be vacant in a
  `:playing` room. A new substitute bot is spawned and the seat becomes
  `:bot_substitute`.

  ## Parameters

  - `room_code` - The unique room code
  - `position` - The seat position to close (`:north`, `:east`, `:south`, `:west`)
  - `requesting_user_id` - User ID of the requester (must be the owner)

  ## Returns

  - `{:ok, room}` - Seat closed successfully (bot spawned)
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :not_owner}` - Requester is not the room owner
  - `{:error, :room_not_playing}` - Room is not in `:playing` status
  - `{:error, :seat_not_vacant}` - Seat is not vacant

  ## Examples

      {:ok, room} = RoomManager.close_seat("A1B2", :east, "owner-user-id")
  """
  @spec close_seat(String.t(), Positions.position(), String.t()) ::
          {:ok, Room.t()}
          | {:error, :room_not_found | :not_owner | :room_not_playing | :seat_not_vacant}
  def close_seat(room_code, position, requesting_user_id) do
    GenServer.call(
      __MODULE__,
      {:close_seat, String.upcase(room_code), position, requesting_user_id}
    )
  end

  @doc """
  Joins a `:playing` room as a substitute player, filling a vacant seat.

  The room must be `:playing` and have a vacant seat (opened by the owner via
  `open_seat/3`). The player is placed in the vacant seat's position and
  receives the current game state. The engine doesn't need changes — the
  position already exists, a bot was playing it, now the human takes over.

  ## Parameters

  - `room_code` - The unique room code
  - `player` - The authenticated user, or a trusted internal user ID

  ## Returns

  - `{:ok, room, position}` - Joined successfully at the given position
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :already_in_room}` - Player is already in another room
  - `{:error, :already_seated}` - Player is already in this room
  - `{:error, :room_not_playing}` - Room is not in `:playing` status
  - `{:error, :no_vacant_seat}` - No vacant seat available
  - `{:error, :account_required}` - A guest tried to claim the open seat

  ## Examples

      {:ok, room, :east} = RoomManager.join_as_substitute("A1B2", "new-player-id")
  """
  @spec join_as_substitute(String.t(), User.t() | String.t()) ::
          {:ok, Room.t(), Positions.position()}
          | {:error,
             :room_not_found
             | :already_in_room
             | :already_seated
             | :room_not_playing
             | :no_vacant_seat
             | :account_required}
  def join_as_substitute(room_code, player) do
    {player_id, guest?} = admission_identity(player)

    GenServer.call(
      __MODULE__,
      {:join_as_substitute, String.upcase(room_code), player_id, guest?}
    )
  end

  defp admission_identity(%User{id: id, guest: guest?})
       when is_binary(id) and is_boolean(guest?),
       do: {id, guest?}

  # String IDs are trusted internal callers such as bots, fixtures and admin tools.
  defp admission_identity(id) when is_binary(id), do: {id, false}

  defp ensure_ordinary_admission(%Room{} = room, player_id, true) do
    if Positions.has_player?(room, player_id),
      do: {:error, :already_seated},
      else: {:error, :account_required}
  end

  defp ensure_ordinary_admission(%Room{}, _player_id, false), do: :ok

  @doc """
  Claims a seat in a room on behalf of an invite redemption.

  The invite carries the room's stable `id` next to its code; a code that now
  belongs to a different room answers `:room_not_found`. A caller who is
  already seated at this table gets their current position back and nothing
  changes (a held seat is reclaimed through the game channel instead). A caller
  whose seat in another room is disconnected is evicted only after the target
  claim validates; a target failure preserves the held seat. A caller connected
  elsewhere gets `:already_in_room`.

  ## Options

  - `:hint` - seat preference from the invite: a position, a team, `:partner`
    (the seat opposite the host) or `nil`; when the hinted seat or team is taken
    the first open seat is used and `hint_honored` is `false`
  - `:position` - an explicit position chosen by the caller; it overrides the
    hint and answers `{:error, {:seat_taken, next_open}}` when taken
  - `:username` and `:display_name` - account names carried unchanged on the
    `invite_redeemed` broadcast

  ## Returns

  - `{:ok, room, position, hint_honored}` - seated, or already seated here
  - `{:error, :room_not_found}` - unknown code, stale `room_id`, or a `:partner`
    hint while the host has no seat
  - `{:error, :room_not_available}` - room is not `:waiting` or `:ready`
  - `{:error, :table_locked}` - the host locked the table
  - `{:error, :kicked}` - the caller was kicked from this room
  - `{:error, :already_in_room}` - the caller is connected in another room
  - `{:error, {:seat_taken, next_open}}` - the explicit position is taken;
    `next_open` lists the open positions in N/E/S/W order
  - `{:error, :room_full}` / `{:error, :invalid_position}` - from `Positions.assign/3`

  Every successful claim broadcasts
  `{:invite_redeemed, %{position, user_id, username, display_name}}` on
  `game:<room_code>`.

  ## Examples

      {:ok, room, :south, true} =
        RoomManager.claim_seat("A1B2", room.id, "user456",
          hint: :south,
          username: "ada_123",
          display_name: "Ada"
        )
  """
  @spec claim_seat(String.t(), Ecto.UUID.t(), String.t(), keyword() | map()) ::
          {:ok, Room.t(), Positions.position(), boolean()}
          | {:error,
             :room_not_found
             | :room_not_available
             | :table_locked
             | :kicked
             | :already_in_room
             | :room_full
             | :invalid_position
             | :profile_unavailable
             | :seat_requires_password
             | {:seat_requires_games, pos_integer(), non_neg_integer()}
             | {:seat_taken, [Positions.position()]}}
  def claim_seat(room_code, room_id, user_id, opts \\ []) do
    claim =
      opts |> Map.new() |> Map.take([:hint, :position, :bound_position, :username, :display_name])

    GenServer.call(
      __MODULE__,
      {:claim_seat, String.upcase(room_code), room_id, user_id, claim}
    )
  end

  @doc """
  Records how long the room's invites stay live.

  `invite_live_until` is the latest `expires_at` of the room's active invites,
  or `nil` when none remain. It drives only the abandoned-room sweep; lobby
  visibility is unchanged. Counts as room activity.

  ## Returns

  - `:ok`
  - `{:error, :room_not_found}` - Room doesn't exist
  """
  @spec note_invite(String.t(), DateTime.t() | nil) :: :ok | {:error, :room_not_found}
  def note_invite(room_code, invite_live_until) do
    GenServer.call(__MODULE__, {:note_invite, String.upcase(room_code), invite_live_until})
  end

  @doc """
  Moves a seated player to a vacant position in a `:waiting` or `:ready` room.

  The host may move anyone; any other seated player may move only themselves.
  The moved seat keeps its owner flag and connection status. Broadcasts
  `{:seat_moved, %{user_id, from, to}}` on `game:<room_code>` plus the usual
  room and lobby updates.

  ## Parameters

  - `room_code` - The unique room code
  - `requesting_user_id` - User ID of the requester
  - `target_user_id` - User ID of the player to move
  - `position` - The vacant position to move to

  ## Returns

  - `{:ok, room}` - Seat moved
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :not_owner}` - A non-host tried to move somebody else
  - `{:error, :room_not_waiting}` - Room is not `:waiting` or `:ready`
  - `{:error, :player_not_in_room}` - The target user is not seated here
  - `{:error, :seat_taken}` - The position holds a player (a held seat counts)
  - `{:error, :invalid_position}` - Invalid position atom
  """
  @spec move_seat(String.t(), String.t(), String.t(), Positions.position()) ::
          {:ok, Room.t()}
          | {:error,
             :room_not_found
             | :not_owner
             | :room_not_waiting
             | :player_not_in_room
             | :seat_taken
             | :invalid_position
             | :profile_unavailable
             | :seat_requires_password
             | {:seat_requires_games, pos_integer(), non_neg_integer()}}
  def move_seat(room_code, requesting_user_id, target_user_id, position) do
    GenServer.call(
      __MODULE__,
      {:move_seat, String.upcase(room_code), requesting_user_id, target_user_id, position}
    )
  end

  @doc """
  Locks or unlocks a `:waiting` or `:ready` table. Only the host may do this.

  A locked table refuses `join_room/3` and `claim_seat/4` with
  `{:error, :table_locked}`; reclaiming a disconnected seat is unaffected.

  ## Returns

  - `{:ok, room}` - Lock state updated
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :not_owner}` - Requester is not the host
  - `{:error, :room_not_waiting}` - Room is not `:waiting` or `:ready`
  """
  @spec set_locked(String.t(), String.t(), boolean()) ::
          {:ok, Room.t()} | {:error, :room_not_found | :not_owner | :room_not_waiting}
  def set_locked(room_code, requesting_user_id, locked) when is_boolean(locked) do
    GenServer.call(
      __MODULE__,
      {:set_locked, String.upcase(room_code), requesting_user_id, locked}
    )
  end

  @doc """
  Kicks the non-host human seated at `position` from a `:waiting` or `:ready`
  room. Only the host may kick.

  The seat is vacated, the user is added to the room's kick list (so they can
  neither join, claim nor substitute into this room again), every game channel
  registered for the user receives `{:force_disconnect, :kicked}`, and
  `{:kicked, %{position, user_id}}` is broadcast on `game:<room_code>`.

  ## Returns

  - `{:ok, room}` - Player kicked
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :not_owner}` - Requester is not the host
  - `{:error, :room_not_waiting}` - Room is not `:waiting` or `:ready`
  - `{:error, :seat_not_kickable}` - The position is vacant, a bot, or the host's seat
  """
  @spec kick_player(String.t(), String.t(), Positions.position()) ::
          {:ok, Room.t()}
          | {:error, :room_not_found | :not_owner | :room_not_waiting | :seat_not_kickable}
  def kick_player(room_code, requesting_user_id, position) do
    GenServer.call(
      __MODULE__,
      {:kick_player, String.upcase(room_code), requesting_user_id, position}
    )
  end

  @doc """
  Resets the RoomManager state for testing purposes.

  This function is only intended for use in tests to clear all rooms and
  player mappings between test runs.

  ## Returns

  - `:ok` - State reset successfully

  ## Examples

      :ok = RoomManager.reset_for_test()
  """
  @spec reset_for_test() :: :ok
  def reset_for_test do
    GenServer.call(__MODULE__, :reset_for_test)
  end

  @spec get_turn_timer(String.t()) :: {:ok, map() | nil} | {:error, :room_not_found}
  def get_turn_timer(room_code) do
    GenServer.call(__MODULE__, {:get_turn_timer, String.upcase(room_code)})
  end

  @spec register_game_channel(String.t(), any(), pid()) :: :ok | {:error, :room_not_found}
  def register_game_channel(room_code, user_id, pid \\ self()) do
    GenServer.call(__MODULE__, {:register_game_channel, String.upcase(room_code), user_id, pid})
  end

  @spec unregister_game_channel(String.t(), any(), pid()) ::
          :last_channel_closed | :channels_remaining | :not_registered
  def unregister_game_channel(room_code, user_id, pid \\ self()) do
    GenServer.call(__MODULE__, {:unregister_game_channel, String.upcase(room_code), user_id, pid})
  end

  @spec readiness(String.t()) :: {:ok, map()} | {:error, :room_not_found}
  def readiness(room_code),
    do: GenServer.call(__MODULE__, {:readiness, String.upcase(room_code)})

  @spec confirm_ready(String.t(), String.t(), any(), pid(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom(), map() | nil}
  def confirm_ready(room_code, room_id, user_id, pid, epoch),
    do:
      GenServer.call(
        __MODULE__,
        {:confirm_ready, String.upcase(room_code), room_id, user_id, pid, epoch}
      )

  @doc """
  Records that a seated player wants another game in this finished room.

  A rematch is the ready check run on a `:finished` room: game over clears the
  ready set and bumps `ready_epoch`, each human confirms against that epoch,
  bots count as agreed, and the last confirmation starts a new game under the
  same room code with the same seats. The client sends nothing about the next
  game; it is derived from the room.
  """
  @spec confirm_rematch(String.t(), String.t(), any(), pid(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom(), map() | nil}
  def confirm_rematch(room_code, room_id, user_id, pid, epoch),
    do:
      GenServer.call(
        __MODULE__,
        {:confirm_rematch, String.upcase(room_code), room_id, user_id, pid, epoch}
      )

  @spec reset_consecutive_timeouts(String.t(), any()) :: :ok | {:error, :room_not_found}
  def reset_consecutive_timeouts(room_code, user_id) do
    GenServer.call(__MODULE__, {:reset_consecutive_timeouts, String.upcase(room_code), user_id})
  end

  @doc "Applies a human action only while the user still controls the seat."
  @spec apply_player_action(String.t(), String.t(), Positions.position(), term()) ::
          {:ok, map()} | {:error, term()}
  def apply_player_action(room_code, user_id, position, action, diagnostics \\ %{}) do
    GenServer.call(
      __MODULE__,
      {:apply_player_action, String.upcase(room_code), user_id, position, action, diagnostics}
    )
  end

  @doc "Applies an action only for the currently tracked substitute controller."
  @spec apply_substitute_action(String.t(), Positions.position(), term()) ::
          {:ok, map()} | {:error, term()}
  def apply_substitute_action(room_code, position, action) do
    GenServer.call(__MODULE__, {:apply_substitute_action, room_code, position, action})
  end

  @doc "Sets pace for the sole human seated with three bots."
  @spec set_pace(String.t(), String.t(), :quick | :own) ::
          {:ok, :quick | :own} | {:error, atom()}
  def set_pace(room_code, user_id, pace) when pace in [:quick, :own],
    do: GenServer.call(__MODULE__, {:set_pace, room_code, user_id, pace})

  @doc "Releases an own-pace hand for its human; otherwise a no-op."
  @spec continue_hand(String.t(), String.t()) :: :ok | {:error, atom()}
  def continue_hand(room_code, user_id),
    do: GenServer.call(__MODULE__, {:continue_hand, room_code, user_id})

  if Mix.env() == :test do
    def set_last_activity_for_test(room_code, datetime) do
      GenServer.call(__MODULE__, {:set_last_activity_for_test, room_code, datetime})
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok) do
    Logger.info("RoomManager started")
    :ok = Phoenix.PubSub.subscribe(PidroServer.PubSub, "room_manager:identity")
    schedule_cleanup()
    send(self(), :startup_sweep)
    schedule_health_check()
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:set_pace, code, user_id, pace}, _from, state) do
    with {:ok, room} <- fetch_room(state, code),
         true <- solo_pace_allowed?(room, user_id),
         :ok <- set_game_pace(room, pace) do
      room = %{room | pace: pace}
      {room, state} = reconcile_turn_timer_for_current_state(room, code, state)
      {:reply, {:ok, pace}, put_room(state, room)}
    else
      false -> {:reply, {:error, :not_solo}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:continue_hand, code, user_id}, _from, state) do
    reply =
      with {:ok, room} <- fetch_room(state, code),
           true <- room.pace == :own and solo_pace_allowed?(room, user_id),
           {:ok, :ok} <- GameAdapter.continue_hand(code) do
        :ok
      else
        _ -> :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:seat_invitations, user_id}, _from, %State{} = state) do
    invitations =
      for {_code, room} <- state.rooms,
          room.status in [:waiting, :ready],
          {position, ^user_id} <- room.config.seat_holds do
        seat_invitation(room, position)
      end

    {:reply, Enum.sort_by(invitations, &{&1.code, &1.position}), state}
  end

  def handle_call({:set_seat_hold, code, host_id, position, user_id}, _from, state) do
    with {:ok, room} <- fetch_room(state, code),
         :ok <- ensure_owner(room, host_id),
         :ok <- ensure_waiting(room),
         :ok <- ensure_unblocked_holds(host_id, [user_id]),
         :ok <- ensure_hold_position(room, position, user_id),
         :ok <- ensure_invitable(state, code, [user_id]) do
      updated = put_seat_hold(room, position, user_id, "released")
      {:reply, {:ok, updated}, put_room(state, updated)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_seat, code, host_id, position, entry}, _from, state) do
    with {:ok, room} <- fetch_room(state, code),
         :ok <- ensure_owner(room, host_id),
         :ok <- ensure_waiting(room),
         {:ok, cleared, bot} <- clear_seat(room, position, entry),
         :ok <- ensure_seat_entry(state, cleared, host_id, position, entry),
         config = Config.put_seat(room.config, position, entry),
         {:ok, updated, new_bot_id} <-
           seat_entry_bot(
             %{
               cleared
               | config: config,
                 seat_hold_started_at:
                   hold_started_at(room, position, config.seat_holds[position])
             },
             position,
             entry
           ) do
      if updated == room do
        {:reply, {:ok, room, nil}, state}
      else
        updated =
          updated
          |> reset_readiness()
          |> maybe_set_ready()
          |> maybe_bump_seat_lifecycle_revision(bot != nil or new_bot_id != nil)
          |> touch_last_activity()

        {bot_id, bot_seat} = bot || {nil, nil}

        player_rooms =
          if state.player_rooms[bot_id] == code,
            do: Map.delete(state.player_rooms, bot_id),
            else: state.player_rooms

        player_rooms =
          if new_bot_id, do: Map.put(player_rooms, new_bot_id, code), else: player_rooms

        bot_pid = release_bot(bot_seat)
        state = %{put_room(state, updated) | player_rooms: player_rooms}

        broadcast_seat_invitation_changes(room, updated)
        broadcast_room(code, updated)
        broadcast_lobby_event({:room_updated, updated})
        broadcast_readiness(updated)
        if bot || new_bot_id, do: broadcast_seat_lifecycle(updated)
        {:reply, {:ok, updated, bot_pid}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decline_seat_hold, code, user_id, position}, _from, state) do
    with {:ok, room} <- fetch_room(state, code),
         ^user_id <- invitation_holds(room)[position] do
      updated = answer_seat_hold(room, position, "not_now")
      {:reply, {:ok, updated}, put_room(state, updated)}
    else
      _ -> {:reply, {:error, :invitation_gone}, state}
    end
  end

  @impl true
  def handle_call({:create_room, host_id, %Config{} = config, seed}, _from, %State{} = state) do
    # If the player is stuck in a room from a previous disconnected session
    # (e.g. browser refresh followed by navigating away), clean it up first.
    # `state` is rebound here, so every error reply below carries the
    # post-eviction state: the caller's stale room stays evicted even when
    # creation fails, and no other room is touched.
    state = maybe_evict_disconnected_player(state, host_id)

    # The collision retry runs inside this callback so `state.rooms` is the
    # authoritative set of live codes for the whole check-then-insert.
    with :ok <- ensure_not_in_other_room(state, host_id, nil),
         :ok <- ensure_invitable(state, nil, Map.values(config.seat_holds)),
         {:ok, room_code} <-
           RoomCodes.generate_unique(
             &Map.has_key?(state.rooms, &1),
             RoomCodes.default_attempts(),
             room_code_generator()
           ) do
      now = DateTime.utc_now()
      {bot_personas, _chance} = Chance.shuffle(Seat.bot_personas(), Chance.from_seed(seed))

      room = %Room{
        id: Ecto.UUID.generate(),
        code: room_code,
        host_id: host_id,
        positions: Positions.empty(),
        seats: init_seats(),
        bot_personas: bot_personas,
        status: :waiting,
        max_players: @max_players,
        created_at: now,
        last_activity: now,
        config: config,
        seat_hold_started_at: Map.new(config.seat_holds, fn {position, _} -> {position, now} end)
      }

      # Auto-assign host to first available position
      {:ok, room_with_host, host_pos} = Positions.assign(room, host_id, :auto)

      state = end_spectating(state, host_id)

      # Update seat for host
      room_with_host = %{
        room_with_host
        | seats:
            Map.put(
              room_with_host.seats,
              host_pos,
              Seat.new_human(host_pos, host_id, is_owner: true)
            )
      }

      %State{} =
        new_state = %State{
          state
          | rooms: Map.put(state.rooms, room_code, room_with_host),
            player_rooms: Map.put(state.player_rooms, host_id, room_code)
        }

      Logger.info("Room created: #{room_code} by host: #{host_id}")
      broadcast_seat_invitation_changes(nil, room_with_host)
      broadcast_lobby_event({:room_created, room_with_host})

      {:reply, {:ok, room_with_host}, new_state}
    else
      {:error, :room_code_exhausted} = error ->
        # Ten misses over a 36^4 space means rooms are leaking, not that the
        # space is full; the count is the number an operator needs first.
        Logger.error(
          "Room code allocation exhausted after #{RoomCodes.default_attempts()} attempts; " <>
            "live rooms: #{map_size(state.rooms)}"
        )

        {:reply, error, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:join_room, room_code, player_id, position, guest?, password},
        _from,
        %State{} = state
      ) do
    with {:ok, %Room{} = room} <- fetch_room(state, room_code) do
      if room.status == :playing,
        do: join_substitute(state, room, player_id, position, guest?),
        else: join_open_seat(state, room, player_id, position, guest?, password)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:join_bot, room_code, bot_id, bot_pid, position}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      %Room{} = room ->
        if bot_holds_seat?(room, bot_id, position),
          do: reattach_bot(state, room, bot_pid, position),
          else: seat_new_bot(state, room, bot_id, bot_pid, position)

      nil ->
        {:reply, {:error, :room_not_found}, state}
    end
  end

  @impl true
  def handle_call({:claim_seat, room_code, room_id, user_id, claim}, _from, %State{} = state) do
    with {:ok, %Room{} = room} <- fetch_room(state, room_code),
         :ok <- ensure_room_id(room, room_id),
         :ok <- ensure_bound_position(room, user_id, Map.get(claim, :bound_position)),
         :ok <- ensure_not_seated_here(room, user_id),
         :ok <- ensure_room_joinable(room, user_id) do
      claim_open_seat(state, room, user_id, claim)
    else
      {:already_seated, room, position} -> {:reply, {:ok, room, position, true}, state}
      {:error, :seat_taken} -> {:reply, {:error, {:seat_taken, []}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:note_invite, room_code, invite_live_until}, _from, %State{} = state) do
    case fetch_room(state, room_code) do
      {:ok, %Room{} = room} ->
        updated_room =
          %Room{room | invite_live_until: invite_live_until}
          |> touch_last_activity()

        {:reply, :ok, put_room(state, updated_room)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_locked, room_code, requesting_user_id, locked}, _from, %State{} = state) do
    with {:ok, %Room{} = room} <- fetch_room(state, room_code),
         :ok <- ensure_owner(room, requesting_user_id),
         :ok <- ensure_waiting(room) do
      updated_room =
        %Room{room | locked: locked}
        |> touch_last_activity()

      Logger.info(
        "Room #{room_code} #{if locked, do: "locked", else: "unlocked"} by host #{requesting_user_id}"
      )

      broadcast_room(room_code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})

      {:reply, {:ok, updated_room}, put_room(state, updated_room)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:move_seat, room_code, requesting_user_id, target_user_id, position},
        _from,
        %State{} = state
      ) do
    with {:ok, %Room{} = room} <- fetch_room(state, room_code),
         :ok <- ensure_can_move(room, requesting_user_id, target_user_id),
         :ok <- ensure_waiting(room),
         {:ok, moved_room, from} <- Positions.move(room, target_user_id, position),
         :ok <-
           ensure_seat_requirement(
             room,
             target_user_id,
             position,
             move_password(room, requesting_user_id, from)
           ) do
      updated_room =
        moved_room
        |> move_seat_struct(from, position)
        |> bump_seat_lifecycle_revision()
        |> reset_readiness()
        |> touch_last_activity()

      Logger.info(
        "Player #{target_user_id} moved from #{from} to #{position} in room #{room_code} " <>
          "by #{requesting_user_id}"
      )

      broadcast_seat_invitation_changes(room, updated_room)
      broadcast_room(room_code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})
      broadcast_seat_lifecycle(updated_room)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:seat_moved, %{user_id: target_user_id, from: from, to: position}}
      )

      broadcast_readiness(updated_room)

      {:reply, {:ok, updated_room}, put_room(state, updated_room)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:kick_player, room_code, requesting_user_id, position},
        _from,
        %State{} = state
      ) do
    with {:ok, %Room{} = room} <- fetch_room(state, room_code),
         :ok <- ensure_owner(room, requesting_user_id),
         :ok <- ensure_waiting(room),
         {:ok, user_id} <- kickable_user(room, position) do
      kicked_room = %Room{room | kicked_ids: Enum.uniq(room.kicked_ids ++ [user_id])}

      case remove_player(state, kicked_room, user_id) do
        {:ok, updated_room, new_state} ->
          Logger.info(
            "Player #{user_id} kicked from #{position} in room #{room_code} " <>
              "by host #{requesting_user_id}"
          )

          notify_user_channels(new_state, room_code, user_id, {:force_disconnect, :kicked})

          Phoenix.PubSub.broadcast(
            PidroServer.PubSub,
            "game:#{room_code}",
            {:kicked, %{position: position, user_id: user_id}}
          )

          {:reply, {:ok, updated_room}, new_state}

        {:closed, new_state} ->
          # Only reachable when the host holds no seat (dev tooling): the
          # kicked player was the last one and the room closed with them.
          {:reply, {:error, :room_not_found}, new_state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:leave_room, room_code, player_id}, from, %State{} = state) do
    case Map.get(state.player_rooms, player_id) do
      ^room_code -> handle_call({:leave_room, player_id}, from, state)
      _other -> {:reply, {:error, :not_in_room}, state}
    end
  end

  def handle_call({:leave_room, player_id}, _from, %State{} = state) do
    case Map.get(state.player_rooms, player_id) do
      nil ->
        {:reply, {:error, :not_in_room}, state}

      room_code ->
        %Room{} = room = state.rooms[room_code]

        cond do
          single_player_human_player?(room, player_id) ->
            Logger.info("Player #{player_id} left single-player room #{room_code}, closing room")
            new_state = remove_room(state, room_code)
            {:reply, :ok, new_state}

          room.status == :playing ->
            leave_live_room(state, room, player_id)

          room.status == :finished ->
            {:reply, :ok, leave_finished_room(state, room, player_id)}

          # Host leaves non-playing room — close the room entirely
          room.host_id == player_id ->
            Logger.info("Host #{player_id} left room #{room_code}, closing room")
            new_state = remove_room(state, room_code)
            {:reply, :ok, new_state}

          true ->
            case remove_player(state, room, player_id) do
              {:ok, _final_room, new_state} ->
                Logger.info("Player #{player_id} left room #{room_code}")
                notify_user_channels(new_state, room_code, player_id, {:force_disconnect, :left})
                {:reply, :ok, new_state}

              {:closed, new_state} ->
                {:reply, :ok, new_state}
            end
        end
    end
  end

  @impl true
  def handle_call({:list_rooms, filter}, _from, %State{} = state) do
    rooms =
      state.rooms
      |> Map.values()
      |> filter_rooms(filter)

    {:reply, rooms, state}
  end

  @impl true
  def handle_call({:list_lobby, user_id}, _from, %State{} = state) do
    rooms =
      state.rooms
      |> Map.values()
      |> Enum.filter(&visible_in_lobby?/1)

    lobby = categorize_lobby(rooms, user_id)
    {:reply, lobby, state}
  end

  @impl true
  def handle_call({:get_room, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil -> {:reply, {:error, :room_not_found}, state}
      room -> {:reply, {:ok, room}, state}
    end
  end

  @impl true
  def handle_call({:get_turn_timer, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        {:reply, {:ok, serialize_turn_timer(room.turn_timer)}, state}
    end
  end

  @impl true
  def handle_call({:register_game_channel, room_code, user_id, pid}, _from, %State{} = state) do
    if Map.has_key?(state.rooms, room_code) do
      {:reply, :ok, register_channel_pid(state, room_code, user_id, pid)}
    else
      {:reply, {:error, :room_not_found}, state}
    end
  end

  @impl true
  def handle_call({:unregister_game_channel, room_code, user_id, pid}, _from, %State{} = state) do
    {result, new_state} = unregister_channel_pid(state, room_code, user_id, pid)

    new_state =
      if result == :last_channel_closed,
        do: disconnect_after_last_channel(new_state, room_code, user_id),
        else: new_state

    {:reply, result, new_state}
  end

  def handle_call({:readiness, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil -> {:reply, {:error, :room_not_found}, state}
      room -> {:reply, {:ok, readiness_snapshot(room)}, state}
    end
  end

  def handle_call(
        {:confirm_ready, room_code, room_id, user_id, pid, epoch},
        _from,
        %State{} = state
      ),
      do: confirm_roster(state, room_code, room_id, user_id, pid, epoch, :start)

  def handle_call(
        {:confirm_rematch, room_code, room_id, user_id, pid, epoch},
        _from,
        %State{} = state
      ),
      do: confirm_roster(state, room_code, room_id, user_id, pid, epoch, :rematch)

  @impl true
  def handle_call({:apply_player_action, room_code, user_id, position, action}, from, state),
    do:
      handle_call({:apply_player_action, room_code, user_id, position, action, %{}}, from, state)

  def handle_call(
        {:apply_player_action, room_code, user_id, position, action, diagnostics},
        _from,
        state
      ) do
    # Serialize authority checks and actions with leave/reclaim. A check in the
    # channel alone would race a takeover between authorization and engine apply.
    result =
      with {:ok, room} <- fetch_room(state, room_code),
           %Seat{occupant_type: :human, status: :connected, user_id: ^user_id} <-
             Map.get(room.seats, position) do
        with {:ok, _game_state} = applied <-
               GameAdapter.apply_action(
                 room_code,
                 position,
                 action,
                 @player_action_call_timeout_ms,
                 diagnostics
               ) do
          record_timed_turn(room, user_id, position)
          applied
        end
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :seat_not_controlled}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:apply_substitute_action, room_code, position, action}, {caller, _}, state) do
    result =
      with {:ok, %Room{status: :playing} = room} <- fetch_room(state, room_code),
           %Seat{status: :bot_substitute, occupant_type: :bot, bot_pid: ^caller} <-
             Map.get(room.seats, position) do
        # Keep admission and engine application serialized with seat transitions.
        # Never retry an ambiguous engine timeout: its action may have committed.
        GameAdapter.apply_action(room_code, position, action, @player_action_call_timeout_ms)
      else
        _ -> {:error, :seat_not_controlled}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_room_status, room_code, new_status}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        %Room{} =
          updated_room =
          %Room{room | status: new_status, last_activity: DateTime.utc_now()}
          |> maybe_bump_seat_lifecycle_revision(room.status != new_status)

        %State{} =
          new_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

        Logger.info("Room #{room_code} status updated: #{room.status} -> #{new_status}")

        broadcast_seat_invitation_changes(room, updated_room)
        broadcast_room(room_code, updated_room)
        broadcast_lobby_event({:room_updated, updated_room})
        if room.status != new_status, do: broadcast_seat_lifecycle(updated_room)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:reset_consecutive_timeouts, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        position = Positions.get_position(room, user_id)
        updated_room = reset_timeout_counter(room, position)
        updated_state = %{state | rooms: Map.put(state.rooms, room_code, updated_room)}
        {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call({:close_room, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      _room ->
        Logger.info("Room #{room_code} closed")
        new_state = remove_room(state, room_code)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:join_spectator_room, room_code, spectator_id}, _from, %State{} = state) do
    cond do
      not Map.has_key?(state.rooms, room_code) ->
        {:reply, {:error, :room_not_found}, state}

      Map.has_key?(state.player_rooms, spectator_id) ->
        {:reply, {:error, :already_in_room}, state}

      Map.has_key?(state.spectator_rooms, spectator_id) ->
        # Repeated Watch is idempotent, including during reconnect grace.
        if state.spectator_rooms[spectator_id] == room_code do
          {:reply, {:ok, state.rooms[room_code]}, state}
        else
          {:reply, {:error, :already_spectating}, state}
        end

      true ->
        %Room{} = room = state.rooms[room_code]

        cond do
          room.status not in [:playing, :finished] ->
            {:reply, {:error, :room_not_available_for_spectators}, state}

          length(room.spectator_ids) >= room.max_spectators ->
            {:reply, {:error, :spectators_full}, state}

          true ->
            updated_spectator_ids = room.spectator_ids ++ [spectator_id]

            %Room{} =
              updated_room = %Room{
                room
                | spectator_ids: updated_spectator_ids,
                  last_activity: DateTime.utc_now()
              }

            %State{} =
              new_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room),
                  spectator_rooms: Map.put(state.spectator_rooms, spectator_id, room_code)
              }

            # Bound capacity even if the Watch command is never followed by a channel attach.
            new_state = schedule_spectator_expiry(new_state, room_code, spectator_id)

            Logger.info("Spectator #{spectator_id} joined room #{room_code}")

            broadcast_room(room_code, updated_room)
            broadcast_lobby_event({:room_updated, updated_room})
            broadcast_seat_lifecycle(updated_room)

            {:reply, {:ok, updated_room}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:leave_spectator, requested_room, spectator_id}, _from, %State{} = state) do
    case Map.get(state.spectator_rooms, spectator_id) do
      nil ->
        {:reply, {:error, :not_spectating}, state}

      room_code when requested_room == nil or requested_room == room_code ->
        {:reply, :ok, end_spectating(state, spectator_id)}

      _other_room ->
        {:reply, {:error, :not_spectating}, state}
    end
  end

  def handle_call({:register_spectator_channel, room_code, user_id, pid}, _from, state) do
    if state.spectator_rooms[user_id] == room_code do
      state = cancel_spectator_expiry(state, room_code, user_id)
      registration = {room_code, user_id, pid}

      monitors =
        if registration in Map.values(state.spectator_monitors),
          do: state.spectator_monitors,
          else: Map.put(state.spectator_monitors, Process.monitor(pid), registration)

      {:reply, :ok, %{state | spectator_monitors: monitors}}
    else
      {:reply, {:error, :not_spectating}, state}
    end
  end

  def handle_call({:unregister_spectator_channel, room_code, user_id, pid}, _from, state) do
    {result, state} = unregister_spectator_pid(state, room_code, user_id, pid)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:is_spectator, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, false, state}

      %Room{} = room ->
        is_spectating = user_id in room.spectator_ids
        {:reply, is_spectating, state}
    end
  end

  @impl true
  def handle_call({:dev_set_position, room_code, position, user_id}, _from, %State{} = state) do
    with {:ok, room} <- fetch_room(state, room_code) do
      # Get previous player at this position (if any)
      previous_player = Map.get(room.positions, position)

      # Clear user from any other positions in this room (prevent occupying multiple seats)
      positions_with_user_cleared =
        if user_id do
          room.positions
          |> Enum.map(fn {pos, id} ->
            if id == user_id && pos != position, do: {pos, nil}, else: {pos, id}
          end)
          |> Enum.into(%{})
        else
          room.positions
        end

      # Set the user at the new position
      updated_positions = Map.put(positions_with_user_cleared, position, user_id)

      # Sync seats with updated positions
      updated_seats = build_seats_from_positions(updated_positions, room.host_id)

      # Update room with new positions, seats, and touch activity
      # Note: Only auto-set to :ready if room is in :waiting status
      # This preserves :playing, :finished, etc. statuses for dev testing
      updated_room =
        %{room | positions: updated_positions, seats: updated_seats}
        |> reset_readiness()
        |> dev_maybe_set_ready()
        |> bump_seat_lifecycle_revision()
        |> touch_last_activity()

      # Update player_rooms mapping
      # Remove previous player's mapping if they were replaced
      new_player_rooms =
        if previous_player && previous_player != user_id do
          Map.delete(state.player_rooms, previous_player)
        else
          state.player_rooms
        end

      # Add new player's mapping if not nil
      new_player_rooms =
        if user_id do
          Map.put(new_player_rooms, user_id, room_code)
        else
          new_player_rooms
        end

      new_state = %State{
        state
        | rooms: Map.put(state.rooms, room_code, updated_room),
          player_rooms: new_player_rooms
      }

      Logger.info(
        "Dev set position #{position} in room #{room_code}: #{inspect(previous_player)} -> #{inspect(user_id)}"
      )

      # Broadcast using established pattern
      broadcast_room(room_code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})
      broadcast_seat_lifecycle(updated_room)
      broadcast_readiness(updated_room)

      # Auto-start game if room is now ready (4 players)
      final_state = maybe_start_game(updated_room, new_state)

      # Return the final room from final_state (may have :playing status if auto-started)
      final_room = Map.get(final_state.rooms, room_code, updated_room)

      {:reply, {:ok, final_room}, final_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:player_disconnect, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        # Playing multiplayer rooms get the hiccup → grace → gone disconnect
        # cascade. Solo rooms hold their only human seat until they reconnect;
        # intentional leaves via leave_room/1 still close them immediately.
        case disconnect_player(state, room, room_code, user_id) do
          {:ok, updated_room, updated_state} ->
            reconnect_policy =
              if single_player_room?(updated_room), do: "seat held", else: "grace period started"

            Logger.info(
              "Player #{user_id} disconnected from room #{room_code}, #{reconnect_policy}"
            )

            broadcast_room(room_code, updated_room)
            broadcast_lobby_event({:room_updated, updated_room})
            broadcast_seat_lifecycle(updated_room)

            {:reply, :ok, updated_state}

          {:error, reason, updated_state} ->
            {:reply, {:error, reason}, updated_state}
        end
    end
  end

  @impl true
  def handle_call({:player_reconnect, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        # Look up the player's seat across all seats — check both user_id
        # (Phase 1: still on seat) and reserved_for (Phase 2/3: bot took over)
        seat_entry = find_seat_for_user(room, user_id)

        cond do
          # Phase 1 or Phase 2: seat found via user_id or reserved_for
          seat_entry != nil ->
            {position, seat} = seat_entry
            handle_seat_reconnection(room, room_code, user_id, position, seat, state)

          # Phase 3: seat permanently botted — player's position has a bot with no reserved_for
          has_permanently_botted_position?(room, user_id) ->
            Logger.info(
              "Player #{user_id} rejected from room #{room_code} — seat permanently filled"
            )

            {:reply, {:error, :seat_permanently_filled}, state}

          true ->
            {:reply, {:error, :player_not_disconnected}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_seat_lifecycle, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil -> {:reply, {:error, :room_not_found}, state}
      room -> {:reply, {:ok, seat_lifecycle_snapshot(room)}, state}
    end
  end

  @impl true
  def handle_call({:keep_bot, room_code, position, user_id, decision_id}, _from, %State{} = state) do
    with {:ok, room} <- fetch_room(state, room_code),
         :ok <- ensure_owner(room, user_id),
         :ok <- ensure_playing(room),
         :ok <- ensure_seat_bot_substitute(room, position),
         {:ok, seat} <- Seat.keep_bot(room.seats[position], decision_id) do
      updated_room =
        %{room | seats: Map.put(room.seats, position, seat)}
        |> bump_seat_lifecycle_revision()
        |> touch_last_activity()

      broadcast_seat_lifecycle(updated_room)

      {:reply, {:ok, updated_room},
       %{state | rooms: Map.put(state.rooms, room_code, updated_room)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:open_seat, room_code, position, requesting_user_id, decision_id},
        _from,
        %State{} = state
      ) do
    with {:ok, room} <- fetch_room(state, room_code),
         :ok <- ensure_owner(room, requesting_user_id),
         :ok <- ensure_playing(room),
         :ok <- ensure_seat_bot_substitute(room, position),
         :ok <- ensure_open_decision(room.seats[position], decision_id) do
      seat = Map.get(room.seats, position)

      # Terminate the bot process
      if seat.bot_pid && Process.alive?(seat.bot_pid) do
        DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, seat.bot_pid)
      end

      # Transition seat to vacant
      {:ok, vacant_seat} = Seat.open_for_substitute(seat)

      updated_room =
        %{room | seats: Map.put(room.seats, position, vacant_seat)}
        |> bump_seat_lifecycle_revision()
        |> touch_last_activity()

      updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

      Logger.info(
        "Seat at #{position} opened for substitute in room #{room_code} by owner #{requesting_user_id}"
      )

      # Broadcast to lobby so the room appears in substitute_needed
      broadcast_room(room_code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})

      # Broadcast on game channel so clients know a seat is available
      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:substitute_available, %{position: position}}
      )

      broadcast_seat_lifecycle(updated_room)

      {:reply, {:ok, updated_room}, updated_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:close_seat, room_code, position, requesting_user_id}, _from, %State{} = state) do
    with {:ok, room} <- fetch_room(state, room_code),
         :ok <- ensure_owner(room, requesting_user_id),
         :ok <- ensure_playing(room),
         :ok <- ensure_seat_vacant(room, position),
         {:start_bot, {:ok, bot_pid}} <-
           {:start_bot, start_substitute_bot(room, position)} do
      seat = Map.get(room.seats, position)

      # Fill seat then transition to bot_substitute (vacant -> connected -> bot path
      # doesn't exist, so we build a bot_substitute seat directly)
      bot_seat = %Seat{
        position: position,
        occupant_type: :bot,
        bot_pid: bot_pid,
        status: :bot_substitute,
        user_id: nil,
        reserved_for: nil,
        is_owner: seat.is_owner
      }

      updated_room =
        %{room | seats: Map.put(room.seats, position, bot_seat)}
        |> bump_seat_lifecycle_revision()
        |> touch_last_activity()

      updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

      Logger.info(
        "Seat at #{position} closed (bot spawned) in room #{room_code} by owner #{requesting_user_id}"
      )

      # Broadcast room update — room no longer has a vacant seat
      broadcast_room(room_code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})

      # Broadcast on game channel
      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:substitute_seat_closed, %{position: position}}
      )

      broadcast_seat_lifecycle(updated_room)

      {:reply, {:ok, updated_room}, updated_state}
    else
      {:start_bot, {:error, reason}} ->
        Logger.error("Bot start failed in room #{room_code}: #{inspect(reason)}")
        {:reply, {:error, :bot_start_failed}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:join_as_substitute, room_code, player_id, guest?},
        _from,
        %State{} = state
      ) do
    with {:ok, room} <- fetch_room(state, room_code) do
      join_substitute(state, room, player_id, nil, guest?)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  if Mix.env() == :test do
    @impl true
    def handle_call({:set_last_activity_for_test, room_code, datetime}, _from, %State{} = state) do
      case Map.get(state.rooms, room_code) do
        nil ->
          {:reply, {:error, :room_not_found}, state}

        %Room{} = room ->
          updated_room = %Room{room | last_activity: datetime}
          updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}
          {:reply, :ok, updated_state}
      end
    end
  end

  @impl true
  def handle_call(:reset_for_test, _from, %State{} = state) do
    Logger.info("RoomManager state reset for testing")
    {:reply, :ok, teardown_state(state)}
  end

  @impl true
  def handle_info({:identity_changed, user_id}, %State{} = state) do
    updated_state =
      state.rooms
      |> Map.values()
      |> Enum.filter(fn room ->
        user_id in Positions.player_ids(room) ||
          Enum.any?(room.seats, fn {_position, seat} -> seat.decision_player_id == user_id end)
      end)
      |> Enum.reduce(state, fn room, acc ->
        updated_room = bump_seat_lifecycle_revision(room)
        broadcast_lobby_event({:room_updated, updated_room})
        broadcast_seat_lifecycle(updated_room)
        put_room(acc, updated_room)
      end)

    {:noreply, updated_state}
  end

  def handle_info(:cleanup_abandoned_rooms, state) do
    now = DateTime.utc_now()
    grace_period_minutes = 5

    # Check based on internal state only (no Presence dependency)
    # Abandoned = :waiting status + NO connected human or spectator + idle for
    # 5 mins, or for invited_waiting_ttl_ms while an invite is live (R21)
    updated_state =
      state.rooms
      |> Enum.filter(fn {_code, room} ->
        abandoned?(room, now, grace_period_minutes)
      end)
      |> Enum.reduce(state, fn {code, _room}, acc_state ->
        Logger.info("Removing abandoned room #{code}")
        remove_room(acc_state, code)
      end)

    schedule_cleanup()
    {:noreply, updated_state}
  end

  # Phase 2 handler — hiccup timer fired, spawn substitute bot and start grace countdown.
  @impl true
  def handle_info({:timeout, ref, {:phase2_start, room_code, position}}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:noreply, state}

      %Room{} = room ->
        seat = Map.get(room.seats, position)

        if is_reference(ref) && room.phase_timers[position] == ref && seat &&
             seat.status == :reconnecting do
          with {:ok, bot_pid} <- start_substitute_bot(room, position) do
            # Calculate remaining grace duration (total grace minus hiccup already elapsed)
            grace_ms = Lifecycle.config(:grace_timeout_ms)
            hiccup_ms = Lifecycle.config(:hiccup_timeout_ms)
            remaining_grace_ms = grace_ms - hiccup_ms
            grace_expires_at = DateTime.add(DateTime.utc_now(), remaining_grace_ms, :millisecond)

            # Transition seat: reconnecting -> grace -> bot_substitute
            {:ok, grace_seat} = Seat.start_grace(seat, grace_expires_at)

            {:ok, bot_seat} = Seat.substitute_bot(grace_seat, bot_pid)

            # Schedule Phase 3 (gone/permanent) timer
            timer_ref =
              :erlang.start_timer(remaining_grace_ms, self(), {:phase3_gone, room_code, position})

            updated_room =
              %{
                room
                | seats: Map.put(room.seats, position, bot_seat),
                  phase_timers: Map.put(room.phase_timers, position, timer_ref)
              }
              |> bump_seat_lifecycle_revision()

            {updated_room, state} =
              reconcile_turn_timer_for_current_state(updated_room, room_code, state)

            updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

            # Broadcast bot substitution event
            Phoenix.PubSub.broadcast(
              PidroServer.PubSub,
              "game:#{room_code}",
              {:bot_substitute_active, %{position: position, user_id: seat.user_id}}
            )

            Logger.info(
              "Phase 2 (Grace): Bot substituted at #{position} in room #{room_code} for user #{seat.user_id}"
            )

            broadcast_seat_lifecycle(updated_room)

            {:noreply, updated_state}
          else
            {:error, reason} ->
              Logger.error("Phase 2 bot start failed in room #{room_code}: #{inspect(reason)}")

              # The hiccup timer already fired. Keep the human seat and rearm
              # a cancellable retry, rather than leaving an inert timer reference.
              timer_ref =
                :erlang.start_timer(
                  Lifecycle.config(:health_check_interval_ms),
                  self(),
                  {:phase2_start, room_code, position}
                )

              room = %{room | phase_timers: Map.put(room.phase_timers, position, timer_ref)}
              {:noreply, %{state | rooms: Map.put(state.rooms, room_code, room)}}
          end
        else
          # Player already reconnected or seat state changed, skip
          {:noreply, state}
        end
    end
  end

  # Phase 3 handler — grace period expired, make bot permanent.
  @impl true
  def handle_info({:timeout, ref, {:phase3_gone, room_code, position}}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:noreply, state}

      %Room{} = room ->
        seat = Map.get(room.seats, position)

        if is_reference(ref) && room.phase_timers[position] == ref && seat &&
             seat.status == :bot_substitute && seat.reserved_for != nil do
          # Record abandonment before clearing reserved_for
          PidroServer.Stats.record_abandonment(seat.reserved_for, room_code, position)

          # Make bot permanent — player can no longer reclaim
          {:ok, permanent_seat} = Seat.make_permanent_bot(seat)
          permanent_seat = remember_departed_name(permanent_seat)

          # Clean up phase timer for this position
          updated_room =
            %{
              room
              | seats: Map.put(room.seats, position, permanent_seat),
                phase_timers: Map.delete(room.phase_timers, position)
            }
            |> bump_seat_lifecycle_revision()

          # If this seat was the owner, promote ownership to next connected human
          updated_room = promote_departed_owner(updated_room, seat.reserved_for)

          updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

          broadcast_room(room_code, updated_room)
          broadcast_lobby_event({:room_updated, updated_room})

          # Broadcast seat permanently botted
          Phoenix.PubSub.broadcast(
            PidroServer.PubSub,
            "game:#{room_code}",
            {:seat_permanently_botted, %{position: position}}
          )

          Logger.info(
            "Phase 3 (Gone): Seat at #{position} in room #{room_code} permanently bot-filled"
          )

          # If the current owner is a connected human, notify them they can open the seat
          maybe_notify_owner_decision(updated_room, room_code, position)
          broadcast_seat_lifecycle(updated_room)

          # Check if zero connected humans remain — schedule auto-close
          maybe_schedule_empty_room_close(updated_room, room_code)

          {:noreply, updated_state}
        else
          # Player already reclaimed or seat state changed, skip
          {:noreply, state}
        end
    end
  end

  # Auto-close handler — fires after empty_room_ttl when zero humans remain.
  @impl true
  def handle_info({:auto_close_empty_room, room_code, game_number}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:noreply, state}

      %Room{} = room ->
        cond do
          room.status != :finished ->
            {:noreply, state}

          # Scheduled by an earlier game in this room: not this game's timer.
          room.game_number != game_number ->
            {:noreply, state}

          has_connected_human?(room) ->
            # A human joined since the timer was scheduled, do nothing
            {:noreply, state}

          true ->
            Logger.info("Auto-closing room #{room_code}: zero connected humans after TTL")

            # Terminate all substitute bot processes
            terminate_room_bots(room)

            # Stop the game process
            GameSupervisor.stop_game(room_code)

            # Cancel any remaining phase timers
            cancel_all_phase_timers(room)

            # Remove the room from state
            new_state = remove_room(state, room_code)
            {:noreply, new_state}
        end
    end
  end

  # Startup sweep — clean up any inconsistent rooms left over from a crash.
  # Closes empty finished rooms, stale waiting rooms, and only closes empty
  # playing rooms when the backing game process is already gone.
  @impl true
  def handle_info(:startup_sweep, %State{} = state) do
    if map_size(state.rooms) == 0 do
      {:noreply, state}
    else
      Logger.info("Running startup sweep on #{map_size(state.rooms)} rooms")
      now = DateTime.utc_now()
      idle_ttl_ms = Lifecycle.config(:idle_waiting_ttl_ms)

      updated_state =
        Enum.reduce(state.rooms, state, fn {code, room}, acc_state ->
          cond do
            room.status == :finished && !has_connected_human?(room) ->
              Logger.info(
                "Startup sweep: closing finished room #{code} with zero connected humans"
              )

              terminate_room_bots(room)
              GameSupervisor.stop_game(code)
              cancel_all_phase_timers(room)
              remove_room(acc_state, code)

            # Playing rooms with zero connected humans are allowed to continue
            # as long as the game process is still alive.
            room.status == :playing && !has_connected_human?(room) ->
              case GameSupervisor.get_game(code) do
                {:ok, _pid} ->
                  acc_state

                {:error, :not_found} ->
                  Logger.info(
                    "Startup sweep: closing orphaned :playing room #{code} with zero connected humans"
                  )

                  terminate_room_bots(room)
                  cancel_all_phase_timers(room)
                  remove_room(acc_state, code)
              end

            # Stale waiting rooms older than idle_waiting_ttl
            room.status == :waiting &&
                DateTime.diff(now, room.last_activity, :millisecond) > idle_ttl_ms ->
              Logger.info("Startup sweep: closing stale :waiting room #{code}")
              remove_room(acc_state, code)

            true ->
              acc_state
          end
        end)

      {:noreply, updated_state}
    end
  end

  # Periodic health check — scans all rooms for inconsistencies.
  # Logs warnings and auto-fixes safe issues (dead bot_pid references).
  @impl true
  def handle_info(:health_check, %State{} = state) do
    updated_state =
      if map_size(state.rooms) == 0 do
        state
      else
        Enum.reduce(state.rooms, state, fn {code, room}, acc_state ->
          room = health_check_room(room, code)
          %State{} = acc_state
          %{acc_state | rooms: Map.put(acc_state.rooms, code, room)}
        end)
      end

    schedule_health_check()
    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:state_update, room_code, payload}, %State{} = state) do
    case {Map.get(state.rooms, room_code), normalize_state_update_payload(payload)} do
      {%Room{} = room, {:ok, game_state, transition_delay_ms, game_instance_id, state_revision}} ->
        if stale_game_snapshot?(state, room_code, game_instance_id, state_revision) do
          {:noreply, state}
        else
          state = put_game_snapshot_cursor(state, room_code, game_instance_id, state_revision)
          game = game_summary(game_state)

          if room.status == :playing and game != room.game do
            broadcast_lobby_event({:room_updated, %{room | game: game}})
          end

          room =
            room
            |> maybe_reset_timeout_counters_for_new_hand(game_state)
            |> Map.put(:last_hand_number, Map.get(game_state, :hand_number))
            |> Map.put(:game, game)

          updated_state = %{state | rooms: Map.put(state.rooms, room_code, room)}

          {updated_room, updated_state} =
            reconcile_turn_timer(room, room_code, game_state, transition_delay_ms, updated_state)

          maybe_schedule_sweep(updated_room, room_code, game_state, transition_delay_ms)

          {:noreply,
           %{updated_state | rooms: Map.put(updated_state.rooms, room_code, updated_room)}}
        end

      _ ->
        {:noreply, state}
    end
  end

  # A finished room nobody rematched closes after `finished_room_ttl_ms`. The
  # game number pins the timer to the game that scheduled it, so it cannot close
  # a rematch, or the room a rematch has since finished in.
  @impl true
  def handle_info({:close_finished_room, room_code, game_number}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      %Room{status: :finished, game_number: ^game_number} ->
        Logger.info("Closing room #{room_code} after game completion")
        {:noreply, remove_room(state, room_code)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:finished_absence, room_code, user_id, token}, %State{} = state) do
    key = {room_code, user_id}

    with ^token <- Map.get(state.finished_absences, key),
         state = %State{state | finished_absences: Map.delete(state.finished_absences, key)},
         %Room{status: :finished} = room <- Map.get(state.rooms, room_code),
         true <- Positions.has_player?(room, user_id),
         false <- channel_alive?(state, room_code, user_id) do
      Logger.info("Player #{user_id} did not return to finished room #{room_code}, leaving")
      {:noreply, leave_finished_room(state, room, user_id)}
    else
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:game_over, room_code, winner, scores}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:noreply, state}

      # Only a game being played can end. A repeat for a room already finished
      # would clear the rematch votes cast since the first one.
      %Room{status: status} when status != :playing ->
        {:noreply, state}

      %Room{} = room ->
        game_state =
          case GameAdapter.get_state(room_code) do
            {:ok, state} -> state
            {:error, _reason} -> nil
          end

        # The game is over: no new controllers or abandonment transitions should
        # run. Preserve reservations so players can still return to the result.
        # Substitutes stop with the game they were covering. The table's own bots
        # stay seated, idle, so a rematch can start without them rejoining; they
        # go when the room does.
        cancel_all_phase_timers(room)

        # Clearing readiness turns the ready check into the rematch vote.
        finished_room =
          room
          |> maybe_cancel_turn_timer()
          |> Map.put(:status, :finished)
          |> Map.put(:phase_timers, %{})
          |> stop_substitute_bots()
          |> reset_readiness()
          |> bump_seat_lifecycle_revision()
          |> touch_last_activity()

        # PID-52: on a successful first commit, fire a NEW post-commit broadcast
        # carrying the per-player progression summaries. The idempotent
        # short-circuit / rollback returns :ok (no summaries) → no broadcast.
        #
        # Persistence is a secondary side effect of finishing a game: a stats /
        # profile write failure must never crash the RoomManager and drop live
        # rooms. Isolate it — log and carry on if it blows up.
        game_instance_id = Map.get(state.active_game_instances, room_code)

        finished_room =
          case persist_completed_game(finished_room, winner, scores, game_state, game_instance_id) do
            {:ok, summaries} when is_map(summaries) and map_size(summaries) > 0 ->
              Phoenix.PubSub.broadcast(
                PidroServer.PubSub,
                "game:#{room_code}",
                {:progression_summary, room_code, summaries}
              )

              %{finished_room | post_game_summaries: summaries}

            _ ->
              finished_room
          end

        updated_state =
          %{state | rooms: Map.put(state.rooms, room_code, finished_room)}
          |> note_absences_at_game_over(finished_room)

        broadcast_room(room_code, finished_room)
        broadcast_lobby_event({:room_updated, finished_room})
        broadcast_seat_lifecycle(finished_room)
        broadcast_readiness(finished_room)
        maybe_schedule_empty_room_close(finished_room, room_code)
        schedule_finished_room_close(finished_room)

        {:noreply, updated_state}
    end
  end

  # A settled hand plays itself out: once the trick on the table has had its
  # pause, the lone trump holder's next trump goes down. The event count pins
  # the play to the state that scheduled it, so a card played meanwhile
  # (the holder tapping one) cancels it. Nothing else plays a settled hand,
  # so a game that did not answer is asked again a few times.
  @impl true
  def handle_info({:sweep_play, room_code, event_seq, retries}, %State{} = state) do
    with %Room{status: :playing, pace: :quick} <- Map.get(state.rooms, room_code),
         {:ok, game_state} <- GameAdapter.get_state(room_code),
         ^event_seq <- length(game_state.events),
         {position, card} <- Play.settled_play(game_state),
         {:ok, _state} <- GameAdapter.apply_action(room_code, position, {:play_card, card}) do
      :ok
    else
      {:error, _reason} when retries > 0 ->
        schedule_sweep_play(room_code, event_seq, retries - 1, sweep_delay_ms())

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:turn_timer_expired, room_code, timer_id, key}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      %Room{} = room ->
        {updated_room, updated_state} =
          handle_turn_timer_expired(room, room_code, timer_id, key, state)

        {:noreply,
         %{updated_state | rooms: Map.put(updated_state.rooms, room_code, updated_room)}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, ref, {:spectator_expired, room_code, user_id}}, state) do
    if state.spectator_timers[{room_code, user_id}] == ref and
         state.spectator_rooms[user_id] == room_code do
      {:noreply, end_spectating(state, user_id)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{} = state) do
    case Map.pop(state.channel_monitors, ref) do
      {nil, _} ->
        case state.spectator_monitors[ref] do
          {room_code, user_id, ^pid} ->
            {_, state} = unregister_spectator_pid(state, room_code, user_id, pid)
            {:noreply, state}

          nil ->
            rooms =
              Map.new(state.rooms, fn {code, room} ->
                seats =
                  Map.new(room.seats, fn {position, seat} ->
                    if seat.bot_pid == pid do
                      {position, recover_substitute_bot(room, seat, code)}
                    else
                      {position, seat}
                    end
                  end)

                {code, %{room | seats: seats}}
              end)

            {:noreply, %{state | rooms: rooms}}
        end

      {{room_code, user_id, ^pid}, channel_monitors} ->
        key = {room_code, user_id}
        remaining = state.channel_pids |> Map.get(key, MapSet.new()) |> MapSet.delete(pid)

        channel_pids =
          if MapSet.size(remaining) == 0 do
            Map.delete(state.channel_pids, key)
          else
            Map.put(state.channel_pids, key, remaining)
          end

        next = %{state | channel_monitors: channel_monitors, channel_pids: channel_pids}

        next =
          if MapSet.size(remaining) == 0,
            do: disconnect_after_last_channel(next, room_code, user_id),
            else: next

        {:noreply, next}
    end
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, %State{} = state) do
    {:noreply, state}
  end

  # RoomManager also receives its own notifications. These describe mutations
  # already applied here; they are not commands to apply them again.
  @impl true
  def handle_info({tag, _}, %State{} = state)
      when tag in [
             :turn_timer_started,
             :turn_timer_cancelled,
             :turn_auto_played,
             :player_reconnecting,
             :player_reconnected,
             :player_reclaimed_seat,
             :bot_substitute_active,
             :seat_permanently_botted,
             :owner_decision_available,
             :owner_changed,
             :substitute_available,
             :substitute_seat_closed,
             :substitute_joined,
             :seat_lifecycle,
             :readiness_updated,
             :invite_redeemed,
             :seat_moved,
             :kicked,
             :seat_invitation_declined
           ],
      do: {:noreply, state}

  @impl true
  def handle_info({:progression_summary, _room_code, _summaries}, %State{} = state),
    do: {:noreply, state}

  @impl true
  def handle_info(message, %State{} = state) do
    PidroServer.Games.UnexpectedMessage.report(__MODULE__, message)
    {:noreply, state}
  end

  ## Private Helper Functions

  # Persist the completed game (game_stats row + profile/rating/XP/achievement
  # rollups) without letting a failure take down the RoomManager. Returns
  # whatever `Stats.save_completed_game/5` returns on success, or `:error` if it
  # raised/exited (e.g. a transient DB problem) — the game has already finished
  # for the players regardless.
  defp persist_completed_game(
         %Room{code: room_code} = finished_room,
         winner,
         scores,
         game_state,
         game_instance_id
       ) do
    Stats.save_completed_game(finished_room, winner, scores, game_state,
      game_instance_id: game_instance_id
    )
  rescue
    error ->
      Logger.error("Failed to persist completed game #{room_code}: #{Exception.message(error)}")

      :error
  catch
    kind, reason ->
      Logger.error("Failed to persist completed game #{room_code}: #{inspect({kind, reason})}")

      :error
  end

  # One consensus, two moments: `:start` opens a waiting table's first game,
  # `:rematch` opens the next game of a finished one.
  defp confirm_roster(%State{} = state, room_code, room_id, user_id, pid, epoch, intent) do
    room = Map.get(state.rooms, room_code)

    snapshot = if room, do: readiness_snapshot(room), else: nil

    registered? =
      MapSet.member?(Map.get(state.channel_pids, {room_code, user_id}, MapSet.new()), pid) and
        Process.alive?(pid)

    cond do
      is_nil(room) ->
        {:reply, {:error, :room_not_found, snapshot}, state}

      room_id != room.id or epoch != room.ready_epoch ->
        {:reply, {:error, :stale_readiness, snapshot}, state}

      not registered? or not human_connected_seat?(room, user_id) ->
        {:reply, {:error, :stale_identity, snapshot}, state}

      not full_table?(room) ->
        {:reply, {:error, :table_not_full, snapshot}, state}

      # Before the repeat-vote reply: everybody is in the ready set of a game
      # they are playing, which must not read as having agreed to a rematch.
      intent == :rematch and room.status != :finished ->
        {:reply, {:error, :room_not_finished, snapshot}, state}

      MapSet.member?(room.ready_player_ids, user_id) ->
        {:reply, {:ok, snapshot}, state}

      intent == :start and room.status not in [:waiting, :ready] ->
        {:reply, {:error, :room_not_waiting, snapshot}, state}

      true ->
        updated = %{
          room
          | ready_player_ids: MapSet.put(room.ready_player_ids, user_id),
            snapshot_revision: room.snapshot_revision + 1
        }

        updated =
          if all_players_ready?(updated),
            do: updated |> retire_finished_game() |> Map.put(:status, :ready),
            else: updated

        next = put_room(state, updated)
        broadcast_readiness(updated)
        next = maybe_start_game(updated, next)
        final = Map.get(next.rooms, room_code, updated)
        {:reply, {:ok, readiness_snapshot(final)}, next}
    end
  end

  defp channel_alive?(%State{} = state, room_code, user_id) do
    state.channel_pids
    |> Map.get({room_code, user_id}, MapSet.new())
    |> Enum.any?(&Process.alive?/1)
  end

  # Leaving a finished room opens the seat for the others rather than ending the
  # table: the room goes back to waiting (`remove_player/3`), where a human can
  # join or the host can seat a bot. A departing host hands the table on. With
  # no other human left to play there is no table to keep.
  defp leave_finished_room(%State{} = state, %Room{code: room_code} = room, player_id) do
    # Anybody else who holds a seat counts, connected or not: a player whose
    # socket is mid-reconnect is still at the table. One who is really gone is
    # removed by their own absence timer, and the last removal closes the room.
    others? =
      Enum.any?(room.seats, fn {_position, seat} ->
        (seat.occupant_type == :human and seat.user_id != player_id) or
          seat.reserved_for not in [nil, player_id]
      end)

    if others? do
      room = hand_on_host(room, player_id)

      case remove_player(state, room, player_id) do
        {:ok, _room, new_state} ->
          notify_user_channels(new_state, room_code, player_id, {:force_disconnect, :left})
          new_state

        {:closed, new_state} ->
          new_state
      end
    else
      Logger.info("Last player #{player_id} left finished room #{room_code}, closing room")
      remove_room(state, room_code)
    end
  end

  defp hand_on_host(%Room{host_id: player_id} = room, player_id) do
    position = Positions.get_position(room, player_id)

    # `promote_owner/1` passes the table on when the owner's seat is not a
    # connected human; the seat is vacated right after.
    case Seat.disconnect(Map.fetch!(room.seats, position)) do
      {:ok, away} ->
        promote_departed_owner(%{room | seats: Map.put(room.seats, position, away)}, player_id)

      # Already away (reconnecting, substituted): promotion needs no nudge.
      {:error, _reason} ->
        promote_departed_owner(room, player_id)
    end
  end

  defp hand_on_host(%Room{} = room, _player_id), do: room

  defp bot_holds_seat?(%Room{} = room, bot_id, position) do
    Map.get(room.positions, position) == bot_id and
      match?(%Seat{occupant_type: :bot, status: :connected}, Map.get(room.seats, position))
  end

  # A bot player restarted by its supervisor comes back for the seat it already
  # holds. Hand the seat its new pid: the roster did not change, so readiness
  # stands, and a rematch waiting on this bot can start.
  defp reattach_bot(%State{} = state, %Room{code: room_code} = room, bot_pid, position) do
    seat = Map.fetch!(room.seats, position)
    updated = %{room | seats: Map.put(room.seats, position, %{seat | bot_pid: bot_pid})}
    next = maybe_start_game(updated, put_room(state, updated))
    {:reply, {:ok, Map.fetch!(next.rooms, room_code), position}, next}
  end

  defp seat_new_bot(%State{} = state, %Room{code: room_code} = room, bot_id, bot_pid, position) do
    with :ok <- ensure_room_open(room),
         :ok <- ensure_not_in_other_room(state, bot_id, room_code),
         {:ok, assigned_room, assigned_position} <- Positions.assign(room, bot_id, position) do
      bot_seat =
        Seat.new_bot(
          assigned_position,
          bot_pid,
          room.seats |> Map.delete(assigned_position) |> Seat.next_bot_persona(room.bot_personas)
        )

      updated =
        assigned_room
        |> Map.put(:seats, Map.put(room.seats, assigned_position, bot_seat))
        |> reset_readiness()
        |> maybe_set_ready()
        |> bump_seat_lifecycle_revision()
        |> touch_last_activity()

      next = put_room_and_player(state, updated, bot_id)
      broadcast_room(room_code, updated)
      broadcast_lobby_event({:room_updated, updated})
      broadcast_readiness(updated)
      broadcast_seat_lifecycle(updated)
      next = maybe_start_game(updated, next)
      {:reply, {:ok, Map.fetch!(next.rooms, room_code), assigned_position}, next}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc false
  defp fetch_room(%State{rooms: rooms}, code) do
    case Map.get(rooms, code) do
      nil -> {:error, :room_not_found}
      room -> {:ok, room}
    end
  end

  @doc false
  defp ensure_not_in_other_room(%State{player_rooms: pr}, player_id, room_code) do
    case Map.get(pr, player_id) do
      nil -> :ok
      ^room_code -> {:error, :already_seated}
      _other -> {:error, :already_in_room}
    end
  end

  # When a player is tracked in a room but their seat is disconnected
  # (reconnecting or bot_substitute), they've abandoned the session.
  # Auto-leave so they can create/join a new room.
  defp maybe_evict_disconnected_player(%State{} = state, player_id) do
    case Map.get(state.player_rooms, player_id) do
      nil ->
        state

      room_code ->
        case Map.get(state.rooms, room_code) do
          nil ->
            # Stale mapping — clean it up
            %State{state | player_rooms: Map.delete(state.player_rooms, player_id)}

          %Room{} = room ->
            evict_when_disconnected(state, room, player_id, disconnected_seat(room, player_id))
        end
    end
  end

  @doc false
  # The player's seat when it is in a disconnected state, else nil.
  defp disconnected_seat(%Room{} = room, player_id) do
    case Positions.get_position(room, player_id) do
      nil ->
        nil

      position ->
        case Map.get(room.seats, position) do
          %Seat{status: status} = seat when status in [:reconnecting, :bot_substitute] -> seat
          _ -> nil
        end
    end
  end

  defp evict_when_disconnected(%State{} = state, %Room{}, _player_id, nil), do: state

  defp evict_when_disconnected(%State{} = state, %Room{code: room_code} = room, player_id, seat) do
    Logger.info(
      "Auto-evicting disconnected player #{player_id} from room #{room_code} (seat: #{seat.status})"
    )

    evict_disconnected_player(state, room, player_id)
  end

  @doc false
  # A single-player room closes with its human. In a `:waiting`/`:ready` room
  # the seat is held (R22): the host's departure closes the table with the
  # host-leave rule, any other held seat is vacated. Elsewhere (`:playing`,
  # `:finished`) only the player mapping is dropped: the seat is already in
  # the cascade, which handles bot replacement and cleanup on its own.
  defp evict_disconnected_player(%State{} = state, %Room{code: room_code} = room, player_id) do
    cond do
      single_player_room?(room) ->
        remove_room(state, room_code)

      room.status not in [:waiting, :ready] ->
        %State{state | player_rooms: Map.delete(state.player_rooms, player_id)}

      room.host_id == player_id ->
        Logger.info(
          "Held host #{player_id} left room #{room_code} for another table, closing room"
        )

        remove_room(state, room_code)

      true ->
        case remove_player(state, room, player_id) do
          {:ok, _final_room, new_state} -> new_state
          {:closed, new_state} -> new_state
        end
    end
  end

  @doc false
  # Status, lock and kick list, in that order: a locked table answers the same
  # way for everybody, matching the invite state a redeem derives first.
  defp ensure_room_joinable(%Room{} = room, user_id) do
    with :ok <- ensure_room_open(room),
         :ok <- ensure_not_locked(room),
         :ok <- ensure_host_unblocked(room, user_id) do
      ensure_not_kicked(room, user_id)
    end
  end

  defp ensure_host_unblocked(room, user_id) do
    if PidroServer.Blocks.blocked?(room.host_id, user_id),
      do: {:error, :seat_taken},
      else: :ok
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Block lookup failed: #{Exception.message(error)}")
      {:error, :profile_unavailable}
  end

  defp ensure_unblocked_holds(host_id, user_ids) do
    if Enum.any?(user_ids, &PidroServer.Blocks.blocked?(host_id, &1)),
      do: {:error, :user_not_found},
      else: :ok
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Block lookup failed: #{Exception.message(error)}")
      {:error, :profile_unavailable}
  end

  defp ensure_room_open(%Room{status: status}) when status in [:waiting, :ready], do: :ok
  defp ensure_room_open(_), do: {:error, :room_not_available}

  defp ensure_not_locked(%Room{locked: true}), do: {:error, :table_locked}
  defp ensure_not_locked(%Room{}), do: :ok

  @doc false
  defp ensure_not_kicked(%Room{kicked_ids: kicked_ids}, user_id) do
    if user_id in kicked_ids, do: {:error, :kicked}, else: :ok
  end

  @doc false
  defp ensure_waiting(%Room{status: status}) when status in [:waiting, :ready], do: :ok
  defp ensure_waiting(_), do: {:error, :room_not_waiting}

  @doc false
  # An invite binds to the room id; the same code may belong to a later room.
  defp ensure_room_id(%Room{id: id}, room_id) when id == room_id, do: :ok
  defp ensure_room_id(_, _), do: {:error, :room_not_found}

  @doc false
  # Not an error: the claim callback answers the current seat unchanged.
  defp ensure_not_seated_here(%Room{} = room, user_id) do
    case Positions.get_position(room, user_id) do
      nil -> :ok
      position -> {:already_seated, room, position}
    end
  end

  @doc false
  # The host may move anyone; a seated player may move only themselves.
  defp ensure_can_move(%Room{}, requesting_user_id, requesting_user_id), do: :ok

  defp ensure_can_move(%Room{} = room, requesting_user_id, _target_user_id),
    do: ensure_owner(room, requesting_user_id)

  @doc false
  # A kickable seat holds a human who is not the host.
  defp kickable_user(%Room{} = room, position) do
    user_id = Map.get(room.positions, position)
    seat = Map.get(room.seats, position)

    if user_id != nil and user_id != room.host_id and
         match?(%Seat{occupant_type: :human}, seat) do
      {:ok, user_id}
    else
      {:error, :seat_not_kickable}
    end
  end

  @doc false
  # Only explicit admission commands use this transition. Validate everything
  # before ending a watch, then commit ownership and both membership indexes together.
  defp join_substitute(
         %State{} = state,
         %Room{code: room_code} = room,
         player_id,
         position,
         guest?
       ) do
    with :ok <- ensure_not_in_other_room(state, player_id, room_code),
         :ok <- ensure_ordinary_admission(room, player_id, guest?),
         :ok <- ensure_playing(room),
         :ok <- ensure_not_locked(room),
         :ok <- ensure_not_kicked(room, player_id),
         :ok <- ensure_host_unblocked(room, player_id),
         {:ok, position} <- substitute_position(room, position) do
      {:ok, filled_seat} = Seat.fill_seat(room.seats[position], player_id)
      state = end_spectating(state, player_id, room_code)

      updated_room =
        %{
          room
          | seats: Map.put(room.seats, position, filled_seat),
            positions: Map.put(room.positions, position, player_id),
            spectator_ids: List.delete(room.spectator_ids, player_id)
        }
        |> reset_timeout_counter(position)
        |> reset_multiplayer_pace()
        |> bump_seat_lifecycle_revision()
        |> touch_last_activity()
        |> restore_owner(position)

      new_state =
        state
        |> put_room_and_player(updated_room, player_id)
        |> release_holds_elsewhere(updated_room, player_id)

      {updated_room, new_state} =
        reconcile_turn_timer_for_current_state(updated_room, room_code, new_state)

      Logger.info(
        "Substitute player #{player_id} joined room #{room_code} at position #{position}"
      )

      broadcast_room(room_code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:substitute_joined, %{position: position, user_id: player_id}}
      )

      broadcast_seat_lifecycle(updated_room)
      {:reply, {:ok, updated_room, position}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Validate the requested claim against the target room before evicting a
  # disconnected seat elsewhere, then perform the two in-memory mutations in
  # the same callback.
  defp claim_open_seat(%State{} = state, %Room{code: room_code} = room, user_id, claim) do
    with :ok <- ensure_can_leave_other_room(state, user_id, room_code),
         {:ok, hint} <- resolve_hint(room, Map.get(claim, :hint)),
         {:ok, updated_room, position, hint_honored} <-
           claim_position(room, user_id, Map.get(claim, :position), hint),
         :ok <- ensure_seat_requirement(room, user_id, position, nil) do
      next_state = maybe_evict_from_other_room(state, user_id, room_code)

      with :ok <- ensure_not_in_other_room(next_state, user_id, room_code) do
        {final_room, new_state} = seat_player(next_state, updated_room, user_id, position)

        Phoenix.PubSub.broadcast(
          PidroServer.PubSub,
          "game:#{room_code}",
          {:invite_redeemed,
           %{
             position: position,
             user_id: user_id,
             username: Map.get(claim, :username),
             display_name: Map.get(claim, :display_name)
           }}
        )

        {:reply, {:ok, final_room, position, hint_honored},
         maybe_start_game(final_room, new_state)}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc false
  # Validate the target join before evicting a disconnected seat elsewhere.
  defp join_open_seat(
         %State{} = state,
         %Room{code: room_code} = room,
         player_id,
         position,
         guest?,
         password
       ) do
    with :ok <- ensure_room_joinable(room, player_id),
         :ok <- ensure_ordinary_admission(room, player_id, guest?),
         :ok <- ensure_can_leave_other_room(state, player_id, room_code),
         {:ok, updated_room, assigned_position} <- Positions.assign(room, player_id, position),
         :ok <-
           ensure_seat_requirement(room, player_id, assigned_position, password && password.()) do
      next_state = maybe_evict_from_other_room(state, player_id, room_code)

      with :ok <- ensure_not_in_other_room(next_state, player_id, room_code) do
        {final_room, new_state} =
          seat_player(next_state, updated_room, player_id, assigned_position)

        {:reply, {:ok, final_room, assigned_position}, maybe_start_game(final_room, new_state)}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A move keeps the password the mover already gave: from one password seat to
  # another, or wherever the host puts them.
  defp move_password(room, requesting_user_id, from) do
    if requesting_user_id == room.host_id or from in room.config.password_seats,
      do: room.config.seat_password
  end

  defp ensure_seat_requirement(room, user_id, position, password) do
    current_seat = room.seats[Positions.get_position(room, user_id)]

    requirement =
      if room.config.seat_holds[position] == user_id,
        do: 0,
        else: Map.get(room.config.seat_requirements, position, 0)

    case current_seat do
      %Seat{occupant_type: :bot} ->
        :ok

      _ ->
        with :ok <- Config.check_password(room.config, position, user_id, password),
             do: ensure_games_played(user_id, requirement)
    end
  end

  defp ensure_games_played(_user_id, 0), do: :ok

  defp ensure_games_played(user_id, min_games) do
    games_played = PidroServer.Profiles.record(user_id).games

    if games_played >= min_games,
      do: :ok,
      else: {:error, {:seat_requires_games, min_games, games_played}}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error, Ecto.Query.CastError] ->
      Logger.error("Seat requirement lookup failed: #{Exception.message(error)}")
      {:error, :profile_unavailable}
  end

  @doc false
  # Runs the disconnected-seat eviction only for a caller tracked in another room.
  defp maybe_evict_from_other_room(%State{} = state, user_id, room_code) do
    case Map.get(state.player_rooms, user_id) do
      nil -> state
      ^room_code -> state
      _other_room -> maybe_evict_disconnected_player(state, user_id)
    end
  end

  # Preserve the existing ALREADY_IN_ROOM precedence for connected seats while
  # allowing a disconnected seat (or stale mapping) to move after target
  # validation succeeds.
  defp ensure_can_leave_other_room(%State{} = state, user_id, room_code) do
    case Map.get(state.player_rooms, user_id) do
      nil ->
        :ok

      ^room_code ->
        :ok

      other_room_code ->
        case Map.get(state.rooms, other_room_code) do
          nil -> :ok
          %Room{} = other_room -> movable_disconnected_seat(other_room, user_id)
        end
    end
  end

  defp movable_disconnected_seat(room, user_id) do
    if disconnected_seat(room, user_id), do: :ok, else: {:error, :already_in_room}
  end

  @doc false
  # `:partner` means the seat opposite the host's current seat.
  defp resolve_hint(%Room{} = room, :partner) do
    case Positions.get_position(room, room.host_id) do
      nil -> {:error, :room_not_found}
      host_position -> {:ok, partner_position(host_position)}
    end
  end

  defp resolve_hint(%Room{}, hint), do: {:ok, hint}

  defp ensure_bound_position(_room, _user_id, nil), do: :ok

  defp ensure_bound_position(room, user_id, position) do
    if room.positions[position] in [nil, user_id] and
         Positions.get_position(room, user_id) in [nil, position],
       do: :ok,
       else: {:error, {:seat_taken, available_positions(room)}}
  end

  @doc false
  # An explicit position wins over the hint and reports the open seats when
  # taken; otherwise the hint is tried with fallback to the first open seat.
  defp claim_position(%Room{} = room, user_id, nil, hint) do
    Positions.assign_with_fallback(room, user_id, hint)
  end

  defp claim_position(%Room{} = room, user_id, position, _hint) do
    case Positions.assign(room, user_id, position) do
      {:ok, updated_room, assigned} -> {:ok, updated_room, assigned, true}
      {:error, :seat_taken} -> {:error, {:seat_taken, Positions.available(room)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  defp ensure_owner(%Room{host_id: user_id, seats: seats}, user_id) do
    if Enum.any?(seats, fn {_, seat} ->
         Seat.owner?(seat) and Seat.connected_human?(seat) and seat.user_id == user_id
       end) do
      :ok
    else
      {:error, :not_owner}
    end
  end

  defp ensure_owner(_, _), do: {:error, :not_owner}

  @doc false
  defp ensure_playing(%Room{status: :playing}), do: :ok
  defp ensure_playing(_), do: {:error, :room_not_playing}

  @doc false
  defp ensure_seat_bot_substitute(%Room{seats: seats}, position) do
    case Map.get(seats, position) do
      %Seat{status: :bot_substitute} -> :ok
      _ -> {:error, :seat_not_bot_substitute}
    end
  end

  defp ensure_open_decision(%Seat{reserved_for: reserved_for}, _decision_id)
       when not is_nil(reserved_for),
       do: {:error, :stale_decision}

  # Legacy manual opening targets the current unreserved bot, not a prompt generation.
  defp ensure_open_decision(%Seat{}, nil), do: :ok

  defp ensure_open_decision(%Seat{decision_id: decision_id}, decision_id)
       when not is_nil(decision_id),
       do: :ok

  defp ensure_open_decision(%Seat{}, _decision_id), do: {:error, :stale_decision}

  @doc false
  defp ensure_seat_vacant(%Room{seats: seats}, position) do
    case Map.get(seats, position) do
      %Seat{occupant_type: :vacant, status: nil} -> :ok
      _ -> {:error, :seat_not_vacant}
    end
  end

  # A hold keeps the time it started while it stays with the same friend.
  defp hold_started_at(room, position, user_id) do
    cond do
      is_nil(user_id) -> Map.delete(room.seat_hold_started_at, position)
      room.config.seat_holds[position] == user_id -> room.seat_hold_started_at
      true -> Map.put(room.seat_hold_started_at, position, DateTime.utc_now())
    end
  end

  # The seat a host is changing, emptied of the bot in it unless it stays a bot.
  defp clear_seat(_room, position, _entry) when position not in [:north, :east, :south, :west],
    do: {:error, :invalid_position}

  defp clear_seat(room, position, entry) do
    case room.seats[position] do
      %Seat{occupant_type: :human} ->
        {:error, :seat_not_vacant}

      %Seat{occupant_type: :bot} = seat when entry != :bot ->
        bot_id = room.positions[position]
        {:ok, room |> Positions.remove(bot_id) |> vacate_seat(position), {bot_id, seat}}

      _ ->
        {:ok, room, nil}
    end
  end

  # A bot entry seats its bot in the host's own call, so nobody can take the
  # seat first. The bot's process, started by the caller, attaches to the seat
  # from its own `init/1` like a restarted bot does.
  defp seat_entry_bot(room, position, :bot) do
    bot_id = "bot_#{room.code}_#{position}"

    case room.seats[position] do
      %Seat{occupant_type: :vacant} ->
        with {:ok, assigned, ^position} <- Positions.assign(room, bot_id, position) do
          persona = room.seats |> Map.delete(position) |> Seat.next_bot_persona(room.bot_personas)
          seats = Map.put(room.seats, position, Seat.new_bot(position, nil, persona))
          {:ok, %{assigned | seats: seats}, bot_id}
        end

      _ ->
        {:ok, room, nil}
    end
  end

  defp seat_entry_bot(room, _position, _entry), do: {:ok, room, nil}

  # A substitute is this manager's own child and stops here. A seated bot
  # belongs to the bot manager; its pid goes back for the caller to stop.
  defp release_bot(%Seat{status: :bot_substitute, bot_pid: pid}) do
    if is_pid(pid),
      do: DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, pid)

    nil
  end

  defp release_bot(%Seat{bot_pid: pid}), do: pid
  defp release_bot(nil), do: nil

  defp ensure_seat_entry(state, room, host_id, position, {:held, user_id}) do
    with :ok <- ensure_unblocked_holds(host_id, [user_id]),
         :ok <- ensure_hold_position(room, position, user_id),
         do: ensure_invitable(state, room.code, [user_id])
  end

  defp ensure_seat_entry(_state, _room, _host_id, _position, _entry), do: :ok

  # A seat invitation never asks a player to leave a table with other people,
  # the same rule that releases their holds once they sit down with people.
  defp ensure_invitable(%State{} = state, room_code, user_ids) do
    with_people? = fn user_id ->
      with code when code not in [nil, room_code] <- state.player_rooms[user_id],
           %Room{seats: seats} <- state.rooms[code] do
        not Seat.alone_with_bots?(seats, user_id)
      else
        _ -> false
      end
    end

    if Enum.any?(user_ids, with_people?), do: {:error, :already_in_room}, else: :ok
  end

  defp ensure_hold_position(room, position, user_id) do
    cond do
      position not in [:north, :east, :south, :west] ->
        {:error, :invalid_position}

      room.positions[position] != nil ->
        {:error, :seat_taken}

      user_id != nil and Positions.has_player?(room, user_id) ->
        {:error, :already_seated}

      user_id != nil and
          Enum.any?(room.config.seat_holds, fn {pos, id} -> pos != position and id == user_id end) ->
        {:error, :already_seated}

      true ->
        :ok
    end
  end

  @doc false
  defp find_vacant_seat_position(%Room{seats: seats}) do
    case Enum.find(seats, fn {_pos, seat} -> Seat.vacant?(seat) end) do
      {position, _seat} -> {:ok, position}
      nil -> {:error, :no_vacant_seat}
    end
  end

  # A join that names a seat (a seat-bound invite, "Sit down" on an
  # invitation) sits exactly there or is refused; anything else takes the
  # first vacant seat as before.
  defp substitute_position(%Room{seats: seats}, position)
       when position in [:north, :east, :south, :west] do
    if Seat.vacant?(seats[position]), do: {:ok, position}, else: {:error, :seat_taken}
  end

  defp substitute_position(%Room{} = room, _position), do: find_vacant_seat_position(room)

  @doc false
  defp maybe_set_ready(%Room{} = room) do
    if ready_to_start?(room), do: %{room | status: :ready}, else: room
  end

  @doc false
  # Dev version that only sets to :ready if currently :waiting
  # This preserves :playing, :finished, etc. for dev testing
  defp dev_maybe_set_ready(%Room{status: :waiting} = room), do: maybe_set_ready(room)
  defp dev_maybe_set_ready(%Room{} = room), do: room

  @doc false
  # Four positions taken and no held seat (R19). Bots count as before.
  defp ready_to_start?(%Room{} = room) do
    full_table?(room) and all_players_ready?(room)
  end

  defp full_table?(room), do: Positions.count(room) == @max_players and not held_seat?(room)

  defp all_players_ready?(room) do
    Enum.all?(room.seats, fn {_position, seat} ->
      seat.occupant_type == :bot or
        (seat.occupant_type == :human and seat.status == :connected and
           MapSet.member?(room.ready_player_ids, seat.user_id))
    end)
  end

  defp human_connected_seat?(room, user_id) do
    Enum.any?(room.seats, fn {_position, seat} ->
      match?(%Seat{occupant_type: :human, user_id: ^user_id, status: :connected}, seat)
    end)
  end

  defp readiness_snapshot(room) do
    ready_players =
      room.seats
      |> Enum.filter(fn {_position, seat} ->
        seat.occupant_type == :bot or MapSet.member?(room.ready_player_ids, seat.user_id)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    %{
      room_id: room.id,
      ready_epoch: room.ready_epoch,
      snapshot_revision: room.snapshot_revision,
      status: room.status,
      config: Config.serialize(room.config),
      positions: room.positions,
      seats:
        Map.new(room.seats, fn {position, seat} ->
          {position, Config.serialize_seat(room.config, seat)}
        end),
      ready_players: ready_players
    }
    |> Map.merge(Room.game_payload(room))
  end

  defp reset_readiness(room) do
    %{
      room
      | ready_player_ids: MapSet.new(),
        ready_epoch: room.ready_epoch + 1,
        snapshot_revision: room.snapshot_revision + 1,
        status: if(room.status == :ready, do: :waiting, else: room.status)
    }
  end

  defp broadcast_readiness(room) do
    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "game:#{room.code}",
      {:readiness_updated, readiness_snapshot(room)}
    )
  end

  @doc false
  # A human seat whose status is anything but `:connected` is held for its
  # player; a table with a held seat waits for the reclaim.
  defp held_seat?(%Room{seats: seats}) do
    Enum.any?(seats, fn {_position, seat} ->
      match?(%Seat{occupant_type: :human, status: status} when status != :connected, seat)
    end)
  end

  @doc false
  defp touch_last_activity(%Room{} = room) do
    %{room | last_activity: DateTime.utc_now()}
  end

  # Disconnect cascade helpers

  @doc false
  # Starts the hiccup cascade for a disconnected player in a :playing room.
  # Updates the seat to :reconnecting and schedules the Phase 2 timer.
  defp start_hiccup_cascade(%Room{} = room, room_code, user_id) do
    position = Positions.get_position(room, user_id)
    seat = Map.get(room.seats, position)

    case seat && Seat.disconnect(seat) do
      {:ok, disconnected_seat} ->
        Stats.record_seat_event(user_id, room_code, "drop")
        room = extend_active_turn_timer(room, room_code, position)
        hiccup_ms = Lifecycle.config(:hiccup_timeout_ms)

        timer_ref =
          :erlang.start_timer(hiccup_ms, self(), {:phase2_start, room_code, position})

        broadcast_player_reconnecting(room_code, user_id, position)

        %{
          room
          | seats: Map.put(room.seats, position, disconnected_seat),
            phase_timers: Map.put(room.phase_timers, position, timer_ref)
        }
        |> bump_seat_lifecycle_revision()

      _ ->
        # Seat not in :connected state or missing, skip cascade
        room
    end
  end

  @doc false
  # Finds a seat that belongs to a user, checking both user_id (Phase 1)
  # and reserved_for (Phase 2/3 where user_id was cleared by bot substitution).
  # Returns {position, seat} or nil.
  defp find_seat_for_user(%Room{seats: seats}, user_id) do
    Enum.find_value(seats, fn {position, seat} ->
      cond do
        seat.user_id == user_id && seat.status == :reconnecting ->
          {position, seat}

        seat.reserved_for == user_id && seat.status in [:grace, :bot_substitute] ->
          {position, seat}

        true ->
          nil
      end
    end)
  end

  @doc false
  # Checks if the user's position (from room.positions) has a permanently-botted seat
  # (Phase 3: :bot_substitute with reserved_for == nil).
  defp has_permanently_botted_position?(%Room{} = room, user_id) do
    case Positions.get_position(room, user_id) do
      nil ->
        false

      position ->
        seat = Map.get(room.seats, position)
        seat != nil && seat.status == :bot_substitute && seat.reserved_for == nil
    end
  end

  @doc false
  # Handles reconnection based on the seat's current cascade phase.
  # Phase 1 (:reconnecting) — cancel timer, reclaim seat
  # Phase 2 (:bot_substitute with reserved_for) — terminate bot, cancel timer, reclaim seat
  # Phase 3 (:bot_substitute without reserved_for) — reject, seat permanently filled
  defp handle_seat_reconnection(room, room_code, user_id, position, seat, %State{} = state) do
    case seat.status do
      :reconnecting ->
        # Phase 1: Cancel timer, reclaim seat. A held seat (solo, own pace,
        # waiting room) has no timer and so no grace to return within.
        in_grace? = Map.has_key?(room.phase_timers, position)
        room = cancel_phase_timer(room, position)

        case Seat.reclaim(seat, user_id) do
          {:ok, reclaimed} ->
            if in_grace?, do: Stats.record_seat_event(user_id, room_code, "return")

            reclaimed_room =
              %{
                room
                | seats: Map.put(room.seats, position, reclaimed),
                  snapshot_revision: room.snapshot_revision + 1,
                  last_activity: DateTime.utc_now()
              }
              |> reset_timeout_counter(position)
              |> restore_owner(position)
              |> bump_seat_lifecycle_revision()

            updated_state = %State{state | rooms: Map.put(state.rooms, room_code, reclaimed_room)}

            {updated_room, updated_state} =
              reconcile_turn_timer_for_current_state(reclaimed_room, room_code, updated_state)

            updated_state = %State{
              updated_state
              | rooms: Map.put(updated_state.rooms, room_code, updated_room)
            }

            Logger.info(
              "Player #{user_id} reconnected during Phase 1 (hiccup) at #{position} in room #{room_code}"
            )

            Phoenix.PubSub.broadcast(
              PidroServer.PubSub,
              "game:#{room_code}",
              {:player_reconnected, %{user_id: user_id, position: position}}
            )

            broadcast_room(room_code, updated_room)
            broadcast_readiness(updated_room)
            broadcast_lobby_event({:room_updated, updated_room})

            broadcast_seat_lifecycle(updated_room)
            # Reclaim restores connectivity, never pre-disconnect readiness.
            {:reply, {:ok, updated_room}, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :bot_substitute when seat.reserved_for == user_id ->
        if reconnect_deadline_expired?(room, seat) do
          # The deadline is authoritative even if the Phase 3 timer message is
          # waiting in this GenServer's mailbox behind the reconnect call.
          {:reply, {:error, :grace_period_expired}, state}
        else
          # Phase 2: Terminate bot, cancel timer, reclaim seat
          room = cancel_phase_timer(room, position)

          # Terminate the substitute bot process
          if seat.bot_pid && Process.alive?(seat.bot_pid) do
            DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, seat.bot_pid)
          end

          case Seat.reclaim(seat, user_id) do
            {:ok, reclaimed} ->
              Stats.record_seat_event(user_id, room_code, "return")

              reclaimed_room =
                %{
                  room
                  | seats: Map.put(room.seats, position, reclaimed),
                    last_activity: DateTime.utc_now()
                }
                |> reset_timeout_counter(position)
                |> restore_owner(position)
                |> bump_seat_lifecycle_revision()

              updated_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, reclaimed_room)
              }

              {updated_room, updated_state} =
                reconcile_turn_timer_for_current_state(reclaimed_room, room_code, updated_state)

              updated_state = %State{
                updated_state
                | rooms: Map.put(updated_state.rooms, room_code, updated_room)
              }

              Logger.info(
                "Player #{user_id} reclaimed seat from bot during Phase 2 (grace) at #{position} in room #{room_code}"
              )

              Phoenix.PubSub.broadcast(
                PidroServer.PubSub,
                "game:#{room_code}",
                {:player_reclaimed_seat, %{user_id: user_id, position: position}}
              )

              broadcast_seat_lifecycle(updated_room)

              broadcast_room(room_code, updated_room)
              broadcast_lobby_event({:room_updated, updated_room})

              {:reply, {:ok, updated_room}, updated_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end

      :bot_substitute ->
        # Phase 3: Bot is permanent (reserved_for is nil), reject reconnection
        Logger.info(
          "Player #{user_id} rejected from room #{room_code} — seat at #{position} permanently filled"
        )

        {:reply, {:error, :seat_permanently_filled}, state}

      _ ->
        {:reply, {:error, :player_not_disconnected}, state}
    end
  end

  defp reconnect_deadline_expired?(%Room{status: :playing, config: %Config{solo: false}}, %Seat{
         grace_expires_at: %DateTime{} = deadline
       }),
       do: DateTime.compare(DateTime.utc_now(), deadline) != :lt

  defp reconnect_deadline_expired?(%Room{}, %Seat{}), do: false

  # Explicit departure surrenders a live seat immediately, without a reclaim window.
  # Start the replacement before releasing membership so startup failure is retryable.
  defp leave_live_room(%State{} = state, %Room{} = room, player_id) do
    position = Positions.get_position(room, player_id)
    seat = Map.get(room.seats, position)

    with {:ok, bot_pid} <- departure_bot(room, seat) do
      # Leaving a table of bots, say to join a friend, abandons nobody.
      if position && not Seat.alone_with_bots?(room.seats, player_id) do
        PidroServer.Stats.record_abandonment(player_id, room.code, position)
      end

      updated_room =
        room
        |> surrender_seat(position, bot_pid)
        |> cancel_phase_timer(position)
        |> Positions.remove(player_id)
        |> touch_last_activity()
        |> promote_departed_owner(player_id)
        |> bump_seat_lifecycle_revision()

      new_state = %{state | player_rooms: Map.delete(state.player_rooms, player_id)}

      {updated_room, new_state} =
        reconcile_turn_timer_for_current_state(updated_room, room.code, new_state)

      new_state = %{new_state | rooms: Map.put(new_state.rooms, room.code, updated_room)}

      notify_user_channels(new_state, room.code, player_id, {:force_disconnect, :left})
      broadcast_departure_takeover(room.code, seat, bot_pid, player_id)
      broadcast_room(room.code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})
      if bot_pid, do: maybe_notify_owner_decision(updated_room, room.code, position)
      broadcast_seat_lifecycle(updated_room)

      {:reply, :ok, new_state}
    else
      {:error, reason} ->
        Logger.error("Bot takeover failed in room #{room.code}: #{inspect(reason)}")
        {:reply, {:error, :bot_start_failed}, state}
    end
  end

  # An owner-opened vacancy (or a replaced former membership) stays open.
  defp departure_bot(_room, nil), do: {:ok, nil}
  defp departure_bot(_room, %Seat{occupant_type: :vacant}), do: {:ok, nil}

  defp departure_bot(room, %Seat{} = seat) do
    if is_pid(seat.bot_pid) and Process.alive?(seat.bot_pid) do
      {:ok, seat.bot_pid}
    else
      start_substitute_bot(room, seat.position)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp surrender_seat(room, _position, nil), do: room

  defp surrender_seat(room, position, bot_pid) do
    {:ok, seat} = Seat.surrender(room.seats[position], bot_pid)
    seat = remember_departed_name(seat)
    %{room | seats: Map.put(room.seats, position, seat)}
  end

  defp remember_departed_name(%Seat{vacated_by: nil} = seat) do
    with {:ok, id} <- Ecto.UUID.cast(seat.decision_player_id),
         %User{} = user <- PidroServer.Accounts.Auth.get_user(id) do
      %{seat | vacated_by: user.display_name || user.username}
    else
      _ -> seat
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Departed player name unavailable: #{Exception.message(error)}")
      seat
  end

  defp remember_departed_name(seat), do: seat

  defp promote_departed_owner(%Room{host_id: player_id} = room, player_id) do
    {_result, promoted_room} = promote_owner(room)
    if promoted_room.host_id != room.host_id, do: broadcast_owner_changed(promoted_room)
    promoted_room
  end

  defp promote_departed_owner(room, _player_id), do: room

  defp restore_owner(%Room{host_id: nil} = room, position) do
    seat = room.seats[position]

    room = %{
      room
      | host_id: seat.user_id,
        seats: Map.put(room.seats, position, %{seat | is_owner: true})
    }

    broadcast_owner_changed(room)
    room
  end

  defp restore_owner(room, _position), do: room

  defp broadcast_owner_changed(room) do
    broadcast_game_event(
      room.code,
      {:owner_changed,
       %{
         new_owner_id: room.host_id,
         new_owner_position:
           Enum.find_value(room.seats, fn {pos, seat} -> if Seat.owner?(seat), do: pos end)
       }}
    )
  end

  defp broadcast_departure_takeover(_room_code, _seat, nil, _player_id), do: :ok

  defp broadcast_departure_takeover(room_code, seat, bot_pid, player_id) do
    if seat.bot_pid != bot_pid do
      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:bot_substitute_active, %{position: seat.position, user_id: player_id}}
      )
    end

    unless seat.status == :bot_substitute and is_nil(seat.reserved_for) do
      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:seat_permanently_botted, %{position: seat.position}}
      )
    end
  end

  @doc false
  # Cancels the phase timer for a given position if one exists.
  defp cancel_phase_timer(%Room{} = room, position) do
    case Map.get(room.phase_timers, position) do
      nil ->
        room

      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{room | phase_timers: Map.delete(room.phase_timers, position)}
    end
  end

  # Empty room auto-close helpers

  @doc false
  # Checks if zero connected humans remain in a finished room.
  # If so, schedules an auto-close after the empty_room_ttl.
  defp maybe_schedule_empty_room_close(%Room{status: :finished} = room, room_code) do
    unless has_connected_human?(room) do
      ttl = Lifecycle.config(:empty_room_ttl_ms)

      Logger.info("Zero connected humans in room #{room_code}, scheduling auto-close in #{ttl}ms")

      Process.send_after(self(), {:auto_close_empty_room, room_code, room.game_number}, ttl)
    end

    :ok
  end

  defp maybe_schedule_empty_room_close(%Room{}, _room_code), do: :ok

  defp schedule_finished_room_close(%Room{code: room_code, game_number: game_number}) do
    Process.send_after(
      self(),
      {:close_finished_room, room_code, game_number},
      Lifecycle.config(:finished_room_ttl_ms)
    )

    :ok
  end

  # The engine has no way out of `:complete`, so a rematch replaces the game
  # process. Stopping it here lets `start_game_for_room/2` start a fresh one
  # under the same room code. A no-op for a room that has not played yet.
  defp retire_finished_game(%Room{status: :finished, code: room_code} = room) do
    _ = GameSupervisor.stop_game(room_code)
    revive_substitute_bots(room)
  end

  defp retire_finished_game(%Room{} = room), do: room

  defp stop_substitute_bots(%Room{seats: seats} = room) do
    seats =
      Map.new(seats, fn
        {position, %Seat{occupant_type: :bot, status: :bot_substitute, bot_pid: pid} = seat} ->
          if is_pid(pid),
            do: DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, pid)

          {position, %{seat | bot_pid: nil}}

        other ->
          other
      end)

    %{room | seats: seats}
  end

  # Game over stopped the substitutes, so bring them back for the rematch.
  defp revive_substitute_bots(%Room{seats: seats} = room) do
    seats =
      Map.new(seats, fn
        {position, %Seat{occupant_type: :bot, status: :bot_substitute, bot_pid: pid} = seat} ->
          if is_pid(pid) and Process.alive?(pid) do
            {position, seat}
          else
            case start_substitute_bot(room, position) do
              {:ok, new_pid} -> {position, %{seat | bot_pid: new_pid}}
              {:error, _reason} -> {position, seat}
            end
          end

        other ->
          other
      end)

    %{room | seats: seats}
  end

  @doc false
  # Terminates all substitute bot processes in a room's seats.
  defp terminate_room_bots(%Room{seats: seats}) do
    Enum.each(seats, fn {_pos, seat} ->
      if seat.bot_pid && Process.alive?(seat.bot_pid) do
        DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, seat.bot_pid)
      end
    end)
  end

  @doc false
  # Cancels all phase timers in a room (used during room cleanup).
  defp cancel_all_phase_timers(%Room{phase_timers: timers}) do
    Enum.each(timers, fn {_pos, timer_ref} -> Process.cancel_timer(timer_ref) end)
  end

  @doc false
  # Notifies the room owner that they can open a permanently-botted seat for a
  # human substitute. Only broadcasts if the owner is a different connected human.
  defp maybe_notify_owner_decision(%Room{} = room, room_code, botted_position) do
    owner_seat =
      room.seats
      |> Map.values()
      |> Enum.find(&Seat.owner?/1)

    if room.seats[botted_position].decision_id && owner_seat &&
         Seat.connected_human?(owner_seat) &&
         owner_seat.position != botted_position do
      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:owner_decision_available, %{position: botted_position, owner_id: owner_seat.user_id}}
      )
    end

    :ok
  end

  # Ownership promotion helpers

  @doc false
  # Promotes ownership to the next connected human when the current owner
  # is no longer available (permanently botted or explicitly left).
  #
  # Candidate order: partner first (N↔S, E↔W), then remaining positions
  # sorted by joined_at.
  #
  # Returns {:ok, updated_room} or {:no_humans, room}.
  defp promote_owner(%Room{} = room) do
    owner_entry = Enum.find(room.seats, fn {_pos, seat} -> Seat.owner?(seat) end)

    case owner_entry do
      nil ->
        {:no_humans, room}

      {_owner_pos, %Seat{occupant_type: :human, status: :connected}} ->
        {:ok, room}

      {owner_pos, _owner_seat} ->
        partner_pos = partner_position(owner_pos)
        other_positions = [:north, :east, :south, :west] -- [owner_pos, partner_pos]

        # Sort remaining positions by joined_at (earliest first, nils last)
        sorted_others =
          Enum.sort_by(other_positions, fn pos ->
            case Map.get(room.seats, pos) do
              %{joined_at: %DateTime{} = dt} -> DateTime.to_unix(dt, :microsecond)
              _ -> :infinity
            end
          end)

        candidates = [partner_pos | sorted_others]

        new_owner_pos =
          Enum.find(candidates, fn pos ->
            seat = Map.get(room.seats, pos)
            seat != nil && Seat.connected_human?(seat)
          end)

        case new_owner_pos do
          nil ->
            seats = Map.new(room.seats, fn {pos, seat} -> {pos, %{seat | is_owner: false}} end)
            {:no_humans, %{room | host_id: nil, seats: seats}}

          pos ->
            old_owner_seat = Map.get(room.seats, owner_pos)
            new_owner_seat = Map.get(room.seats, pos)

            updated_seats =
              room.seats
              |> Map.put(owner_pos, %{old_owner_seat | is_owner: false})
              |> Map.put(pos, %{new_owner_seat | is_owner: true})

            {:ok, %{room | seats: updated_seats, host_id: new_owner_seat.user_id}}
        end
    end
  end

  @doc false
  defp partner_position(:north), do: :south
  defp partner_position(:south), do: :north
  defp partner_position(:east), do: :west
  defp partner_position(:west), do: :east

  # Seat management helpers

  @doc false
  defp init_seats do
    %{
      north: Seat.new_vacant(:north),
      east: Seat.new_vacant(:east),
      south: Seat.new_vacant(:south),
      west: Seat.new_vacant(:west)
    }
  end

  @doc false
  defp vacate_seat(%Room{seats: seats} = room, position) do
    %{room | seats: Map.put(seats, position, Seat.new_vacant(position))}
  end

  @doc false
  defp build_seats_from_positions(positions, host_id) do
    Map.new(positions, fn {pos, user_id} ->
      seat =
        if user_id do
          Seat.new_human(pos, user_id, is_owner: user_id == host_id)
        else
          Seat.new_vacant(pos)
        end

      {pos, seat}
    end)
  end

  @doc false
  defp put_room(%State{} = state, %Room{code: code} = room) do
    %State{state | rooms: Map.put(state.rooms, code, room)}
  end

  @doc false
  defp put_room_and_player(%State{} = state, %Room{code: code} = room, player_id) do
    %State{
      state
      | rooms: Map.put(state.rooms, code, room),
        player_rooms: Map.put(state.player_rooms, player_id, code)
    }
  end

  @doc false
  # Fills the seat a player was just assigned in `Positions`, runs the ready
  # check, stores the room and player mapping and broadcasts the room and lobby
  # updates. Returns `{room, state}`; the caller starts the game when the room
  # became `:ready` (see `maybe_start_game/2`).
  defp seat_player(%State{} = state, %Room{code: room_code} = room, player_id, position) do
    {:ok, filled_seat} = Seat.fill_seat(room.seats[position], player_id)
    state = end_spectating(state, player_id, room_code)
    room = %{room | spectator_ids: List.delete(room.spectator_ids, player_id)}

    final_room =
      %{room | seats: Map.put(room.seats, position, filled_seat)}
      |> reset_multiplayer_pace()
      |> reset_readiness()
      |> maybe_set_ready()
      |> bump_seat_lifecycle_revision()
      |> touch_last_activity()

    new_state =
      state
      |> put_room_and_player(final_room, player_id)
      |> release_holds_elsewhere(final_room, player_id)

    broadcast_seat_invitation_changes(state.rooms[room_code], final_room)

    Logger.info(
      "Player #{player_id} joined room #{room_code} at position #{position} " <>
        "(#{Positions.count(final_room)}/#{@max_players})"
    )

    broadcast_room(room_code, final_room)
    broadcast_lobby_event({:room_updated, final_room})
    broadcast_seat_lifecycle(final_room)
    broadcast_readiness(final_room)

    {final_room, new_state}
  end

  @doc false
  defp maybe_start_game(%Room{status: :ready} = room, %State{} = state) do
    channels_alive? =
      Enum.all?(room.seats, fn
        {_position, %Seat{occupant_type: :bot, bot_pid: pid}} ->
          is_pid(pid) and Process.alive?(pid)

        {_position, %Seat{user_id: user_id}} ->
          state.channel_pids
          |> Map.get({room.code, user_id}, MapSet.new())
          |> Enum.any?(&Process.alive?/1)
      end)

    if ready_to_start?(room) and channels_alive?,
      do: start_game_for_room(room, state),
      else: state
  end

  defp maybe_start_game(%Room{}, %State{} = state), do: state

  @doc false
  # Removes a non-host player: clears their position, vacates the seat and
  # drops the player mapping. Closes the room when it becomes empty
  # (`{:closed, state}`); otherwise drops the room back to `:waiting`, touches
  # activity, broadcasts the room and lobby updates and returns
  # `{:ok, room, state}`.
  defp remove_player(%State{} = state, %Room{code: room_code} = room, player_id) do
    player_position = Positions.get_position(room, player_id)

    # A finished room that loses a player reopens as a waiting table, so its
    # completed game goes: the next start must be a new game, not this one.
    # Retiring revives substitute bots, so the leaver's seat is vacated first:
    # a substitute started for it would be orphaned by the vacate.
    updated_room =
      room
      |> Positions.remove(player_id)
      |> vacate_seat(player_position)
      |> retire_finished_game()
      |> reset_readiness()

    if Positions.count(updated_room) == 0 do
      Logger.info("Room #{room_code} is now empty, deleting")
      {:closed, remove_room(state, room_code)}
    else
      final_room =
        updated_room
        |> Map.put(:status, :waiting)
        |> bump_seat_lifecycle_revision()
        |> touch_last_activity()

      %State{} =
        new_state = %State{
          state
          | rooms: Map.put(state.rooms, room_code, final_room),
            player_rooms: Map.delete(state.player_rooms, player_id)
        }

      broadcast_room(room_code, final_room)
      broadcast_readiness(final_room)
      broadcast_lobby_event({:room_updated, final_room})
      broadcast_seat_lifecycle(final_room)

      # If this was a :playing room and no connected humans remain,
      # schedule auto-close (bots may still be playing)
      if room.status == :playing do
        maybe_schedule_empty_room_close(final_room, room_code)
      end

      {:ok, final_room, new_state}
    end
  end

  @doc false
  # Carries the seat struct (owner flag, status, join time) to its new position
  # and leaves a vacant seat behind.
  defp move_seat_struct(%Room{seats: seats} = room, from, to) do
    %Seat{} = seat = Map.fetch!(seats, from)
    moved_seat = %Seat{seat | position: to}

    %{room | seats: seats |> Map.put(to, moved_seat) |> Map.put(from, Seat.new_vacant(from))}
  end

  @doc false
  # Delivers a message to every game channel registered for the user in the
  # room (the same delivery as `maybe_force_disconnect/4`).
  defp notify_user_channels(%State{} = state, room_code, user_id, message) do
    state.channel_pids
    |> Map.get({room_code, user_id}, MapSet.new())
    |> Enum.each(&send(&1, message))
  end

  @doc false
  @spec remove_room(State.t(), String.t()) :: State.t()
  defp remove_room(%State{} = state, room_code) do
    case Map.get(state.rooms, room_code) do
      nil ->
        state

      room ->
        maybe_cancel_turn_timer(room)
        cancel_all_phase_timers(room)
        terminate_room_bots(room)
        state = unsubscribe_from_game_topic(state, room_code)
        state = drop_room_channel_registrations(state, room_code)

        %State{} =
          state =
          Enum.reduce(room.spectator_ids, state, &drop_spectator_connections(&2, room_code, &1))

        _ = GameSupervisor.stop_game(room_code)

        # Remove room and all player/spectator mappings
        new_rooms = Map.delete(state.rooms, room_code)

        player_ids = Positions.player_ids(room)

        new_player_rooms =
          Enum.reduce(player_ids, state.player_rooms, fn player_id, acc ->
            Map.delete(acc, player_id)
          end)

        new_spectator_rooms =
          Enum.reduce(room.spectator_ids, state.spectator_rooms, fn spectator_id, acc ->
            Map.delete(acc, spectator_id)
          end)

        %State{} =
          new_state = %State{
            state
            | rooms: new_rooms,
              player_rooms: new_player_rooms,
              spectator_rooms: new_spectator_rooms,
              game_snapshot_cursors: Map.delete(state.game_snapshot_cursors, room_code),
              active_game_instances: Map.delete(state.active_game_instances, room_code),
              finished_absences:
                Map.reject(state.finished_absences, fn {{code, _user_id}, _token} ->
                  code == room_code
                end)
          }

        broadcast_seat_invitation_changes(room, nil)
        broadcast_room(room_code, nil)
        broadcast_lobby_event({:room_closed, room_code})

        new_state
    end
  end

  @doc false
  @spec broadcast_lobby_event(any()) :: :ok
  defp broadcast_lobby_event(event) do
    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "lobby:updates",
      event
    )
  end

  defp seat_invitation(room, position) do
    %{
      code: room.code,
      position: position,
      host_id: room.host_id,
      rule_set: Atom.to_string(room.config.rule_set),
      held_since: DateTime.to_iso8601(Map.fetch!(room.seat_hold_started_at, position)),
      join_as: join_as(room, position)
    }
  end

  defp join_as(room, position) do
    if Positions.get_position(room, room.host_id) == partner_position(position),
      do: "partner",
      else: "opponent"
  end

  defp invitation_holds(%Room{status: status} = room) when status in [:waiting, :ready],
    do: room.config.seat_holds

  defp invitation_holds(_room), do: %{}

  # Sets or releases one hold: the seat goes back to open with its requirement,
  # readiness resets and the room, lobby and invitee hear about it.
  defp put_seat_hold(room, position, user_id, gone_reason) do
    holds =
      if user_id,
        do: Map.put(room.config.seat_holds, position, user_id),
        else: Map.delete(room.config.seat_holds, position)

    updated =
      %{
        room
        | config: %{room.config | seat_holds: holds},
          seat_hold_started_at: hold_started_at(room, position, user_id)
      }
      |> reset_readiness()
      |> touch_last_activity()

    broadcast_seat_invitation_changes(room, updated, gone_reason)
    broadcast_room(room.code, updated)
    broadcast_lobby_event({:room_updated, updated})
    broadcast_readiness(updated)
    updated
  end

  # The invitee answered the hold at `position`: "not_now", or "sat_elsewhere".
  defp answer_seat_hold(room, position, reason) do
    user_id = room.config.seat_holds[position]
    updated = put_seat_hold(room, position, nil, "declined")

    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "game:#{room.code}",
      {:seat_invitation_declined, %{position: position, user_id: user_id, reason: reason}}
    )

    updated
  end

  # Sitting down with another human answers every invitation those humans hold
  # in other rooms; sitting alone or with bots answers none.
  defp release_holds_elsewhere(%State{} = state, %Room{code: code} = room, player_id) do
    if Seat.alone_with_bots?(room.seats, player_id) do
      state
    else
      humans = for {_, %Seat{occupant_type: :human, user_id: id}} <- room.seats, do: id

      declined =
        for {other_code, other} <- state.rooms,
            other_code != code,
            {position, user_id} <- invitation_holds(other),
            user_id in humans,
            do: {other_code, position}

      Enum.reduce(declined, state, fn {other_code, position}, acc ->
        put_room(acc, answer_seat_hold(acc.rooms[other_code], position, "sat_elsewhere"))
      end)
    end
  end

  # Why a held seat stopped inviting its user. Taking the seat drops it quietly
  # like declining; a host release passes "released".
  defp gone_reason(nil, _user_id, _reason), do: "closed"

  defp gone_reason(%Room{status: status}, _user_id, _reason)
       when status not in [:waiting, :ready],
       do: "started"

  defp gone_reason(room, user_id, reason),
    do: if(Positions.has_player?(room, user_id), do: "declined", else: reason)

  defp broadcast_seat_invitation_changes(before, after_room, reason \\ "released") do
    old_holds = invitation_holds(before)
    new_holds = invitation_holds(after_room)

    if before do
      for {position, user_id} <- old_holds, new_holds[position] != user_id do
        Phoenix.PubSub.broadcast(
          PidroServer.PubSub,
          "lobby:invitations:#{user_id}",
          {:seat_invitation_gone, user_id,
           %{
             code: before.code,
             position: position,
             reason: gone_reason(after_room, user_id, reason)
           }}
        )
      end
    end

    # A host who moves seats turns a partner seat into an opponent seat, so that
    # invitation goes out again with its new `join_as`.
    if after_room do
      for {position, user_id} <- new_holds,
          old_holds[position] != user_id or
            join_as(before, position) != join_as(after_room, position) do
        Phoenix.PubSub.broadcast(
          PidroServer.PubSub,
          "lobby:invitations:#{user_id}",
          {:seat_invitation, user_id, seat_invitation(after_room, position)}
        )
      end
    end
  end

  @doc false
  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_abandoned_rooms, :timer.minutes(1))
  end

  @doc false
  @spec schedule_health_check() :: reference()
  defp schedule_health_check do
    interval = Lifecycle.config(:health_check_interval_ms)
    Process.send_after(self(), :health_check, interval)
  end

  @doc false
  # Checks a single room for inconsistencies and auto-fixes safe issues.
  # Returns the (possibly updated) room.
  defp health_check_room(%Room{} = room, room_code) do
    room
    |> check_dead_bot_pids(room_code)
    |> check_expired_grace_periods(room_code)
    |> check_missing_game_process(room_code)
  end

  # RoomManager is the sole restart authority for replacement controllers.
  # A delayed DOWN after reclaim/open or another recovery cannot resurrect a seat.
  defp start_substitute_bot(room, position) do
    with {:ok, pid} <- SubstituteBot.start(room.code, position, room.config.bot_difficulty) do
      Process.monitor(pid)
      {:ok, pid}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp recover_substitute_bot(
         %Room{status: :playing} = room,
         %Seat{occupant_type: :bot, status: :bot_substitute} = seat,
         room_code
       ) do
    case start_substitute_bot(room, seat.position) do
      {:ok, pid} ->
        Logger.info("Recovered substitute bot in room #{room_code} at #{seat.position}")
        %{seat | bot_pid: pid}

      {:error, reason} ->
        Logger.error("Substitute bot recovery failed in #{room_code}: #{inspect(reason)}")
        %{seat | bot_pid: nil}
    end
  end

  defp recover_substitute_bot(_room, seat, _room_code), do: %{seat | bot_pid: nil}

  defp check_dead_bot_pids(%Room{seats: seats} = room, room_code) do
    updated_seats =
      Map.new(seats, fn {pos, seat} ->
        if (seat.bot_pid && !Process.alive?(seat.bot_pid)) ||
             (seat.occupant_type == :bot && seat.status == :bot_substitute &&
                is_nil(seat.bot_pid) && room.status == :playing) do
          {pos, recover_substitute_bot(room, seat, room_code)}
        else
          {pos, seat}
        end
      end)

    %{room | seats: updated_seats}
  end

  # Log warning for expired grace periods that weren't transitioned
  defp check_expired_grace_periods(%Room{seats: seats} = room, room_code) do
    now = DateTime.utc_now()

    Enum.each(seats, fn {pos, seat} ->
      if seat.grace_expires_at && DateTime.compare(now, seat.grace_expires_at) == :gt do
        Logger.warning(
          "Health check: expired grace period at #{pos} in room #{room_code} " <>
            "(expired at #{DateTime.to_iso8601(seat.grace_expires_at)})"
        )
      end
    end)

    room
  end

  # Log warning for :playing rooms with no game process
  defp check_missing_game_process(%Room{status: :playing} = room, room_code) do
    case GameSupervisor.get_game(room_code) do
      {:ok, _pid} ->
        :ok

      {:error, :not_found} ->
        Logger.warning("Health check: :playing room #{room_code} has no game process")
    end

    room
  end

  defp check_missing_game_process(room, _room_code), do: room

  defp abandoned?(room, now, grace_period_minutes) do
    idle_threshold_ms = idle_threshold_ms(room, now, grace_period_minutes)
    idle? = DateTime.diff(now, room.last_activity, :millisecond) > idle_threshold_ms

    active_spectator_count = length(room.spectator_ids)

    # A waiting room is abandoned if idle AND has no connected humans (a held
    # seat is not one). Previously this checked Positions.count == 0, which
    # missed rooms where seat status was never cleared on disconnect.
    room.status == :waiting && idle? && !has_connected_human?(room) &&
      active_spectator_count == 0
  end

  @doc false
  # While an invite is live (`invite_live_until` in the future) the room waits
  # for `invited_waiting_ttl_ms` before it counts as abandoned (R21); otherwise
  # the sweep's grace period applies.
  defp idle_threshold_ms(%Room{invite_live_until: %DateTime{} = live_until}, now, grace_minutes) do
    if DateTime.compare(live_until, now) == :gt do
      Lifecycle.config(:invited_waiting_ttl_ms)
    else
      :timer.minutes(grace_minutes)
    end
  end

  defp idle_threshold_ms(%Room{}, _now, grace_minutes), do: :timer.minutes(grace_minutes)

  # Test hook: an optional zero-arity generator under
  # `config :pidro_server, PidroServer.Games.RoomCodes, generator: fun`
  # replaces the CSPRNG draw. Read at call time so tests can set and restore
  # it; the key is absent in every config file.
  @spec room_code_generator() :: RoomCodes.generator()
  defp room_code_generator do
    :pidro_server
    |> Application.get_env(RoomCodes, [])
    |> Keyword.get(:generator, &RoomCodes.random/0)
  end

  @doc false
  @spec filter_rooms([Room.t()], :all | :waiting | :ready | :playing | :available) :: [Room.t()]
  defp filter_rooms(rooms, :all), do: rooms
  defp filter_rooms(rooms, :waiting), do: Enum.filter(rooms, &(&1.status == :waiting))
  defp filter_rooms(rooms, :ready), do: Enum.filter(rooms, &(&1.status == :ready))
  defp filter_rooms(rooms, :playing), do: Enum.filter(rooms, &(&1.status == :playing))

  defp filter_rooms(rooms, :available) do
    Enum.filter(rooms, &(&1.status in [:waiting, :ready, :playing]))
  end

  defp single_player_human_player?(%Room{} = room, player_id) do
    if single_player_room?(room) do
      case Positions.get_position(room, player_id) do
        nil ->
          false

        position ->
          case Map.get(room.seats, position) do
            %Seat{occupant_type: :human, substitute: false} -> true
            _ -> false
          end
      end
    else
      false
    end
  end

  @spec categorize_lobby([Room.t()], String.t() | nil) :: %{
          my_rejoinable: [Room.t()],
          open_tables: [Room.t()],
          substitute_needed: [Room.t()],
          spectatable: [Room.t()]
        }
  defp categorize_lobby(rooms, user_id) do
    initial = %{my_rejoinable: [], open_tables: [], substitute_needed: [], spectatable: []}

    Enum.reduce(rooms, initial, fn room, acc ->
      case lobby_category(room, user_id) do
        nil -> acc
        category -> Map.update!(acc, category, &[room | &1])
      end
    end)
  end

  @doc "Authoritative category shared by initial lobby reads and incremental broadcasts."
  @spec lobby_category(Room.t(), String.t() | nil) ::
          :my_rejoinable | :open_tables | :substitute_needed | :spectatable | nil
  def lobby_category(room, user_id) do
    cond do
      not has_connected_human?(room) ->
        nil

      room.status == :playing && user_id != nil && Seat.reserved_for_user?(room.seats, user_id) ->
        :my_rejoinable

      room.status == :waiting && available_positions(room) != [] ->
        :open_tables

      room.status == :playing && available_positions(room) != [] ->
        :substitute_needed

      room.status == :playing && length(room.spectator_ids) < room.max_spectators ->
        :spectatable

      true ->
        nil
    end
  end

  defp has_connected_human?(%Room{seats: seats}) when map_size(seats) == 0, do: false

  defp has_connected_human?(%Room{seats: seats}) do
    Enum.any?(seats, fn {_pos, seat} -> Seat.connected_human?(seat) end)
  end

  @doc false
  @spec broadcast_room(String.t(), Room.t() | nil) :: :ok
  defp broadcast_room(room_code, room) do
    event = if room, do: {:room_update, room}, else: {:room_closed}

    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "room:#{room_code}",
      event
    )

    :ok
  end

  @doc false
  @spec start_game_for_room(Room.t(), State.t()) :: State.t()
  defp start_game_for_room(%Room{} = room, %State{} = state) do
    player_ids = Positions.player_ids(room)
    Logger.info("Starting game for room #{room.code} with players: #{inspect(player_ids)}")

    participants = PidroServer.GameArchive.participants(room.seats)

    started =
      case GameSupervisor.start_game(room.code, room.config.rule_set, room.pace, participants) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        result -> result
      end

    # A game that cannot give its first snapshot has not started: without its
    # instance id every later update from it would be discarded as stale.
    with {:ok, _pid} <- started,
         {:ok, snapshot} <- GameAdapter.get_snapshot(room.code) do
      finish_game_start(room, snapshot, state)
    else
      {:error, reason} ->
        Logger.error("Failed to start game for room #{room.code}: #{inspect(reason)}")
        state
    end
  end

  defp finish_game_start(%Room{} = room, snapshot, %State{} = state) do
    Logger.info("Game started successfully for room #{room.code}")

    %Room{} =
      updated_room =
      %Room{
        room
        | status: :playing,
          snapshot_revision: room.snapshot_revision + 1,
          turn_timer: nil,
          consecutive_timeouts: %{},
          last_hand_number: nil,
          game: game_summary(snapshot.state),
          game_number: room.game_number + 1,
          game_started_at: DateTime.utc_now(),
          post_game_summaries: %{}
      }
      |> bump_seat_lifecycle_revision()

    %State{} =
      new_state =
      %State{state | rooms: Map.put(state.rooms, room.code, updated_room)}
      |> subscribe_to_game_topic(room.code)
      |> put_active_game_instance(room.code, snapshot)

    broadcast_seat_invitation_changes(room, updated_room)
    broadcast_room(room.code, updated_room)
    broadcast_readiness(updated_room)
    broadcast_lobby_event({:room_updated, updated_room})
    broadcast_seat_lifecycle(updated_room)
    broadcast_initial_game_state(room.code, snapshot)
    new_state
  end

  defp game_summary(state) do
    %{hand: Map.get(state, :hand_number), scores: Map.get(state, :cumulative_scores, %{})}
  end

  @spec broadcast_initial_game_state(String.t(), map()) :: :ok
  defp broadcast_initial_game_state(room_code, snapshot) do
    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "game:#{room_code}",
      {:state_update, room_code, Map.put(snapshot, :transition_delay_ms, 0)}
    )
  end

  defp normalize_state_update_payload(
         %{
           state: game_state,
           transition_delay_ms: transition_delay_ms
         } = payload
       )
       when is_map(game_state) and is_integer(transition_delay_ms) do
    {:ok, game_state, transition_delay_ms, Map.get(payload, :game_instance_id),
     Map.get(payload, :state_revision)}
  end

  defp normalize_state_update_payload(%{state: game_state}) when is_map(game_state) do
    {:ok, game_state, 0, nil, nil}
  end

  defp normalize_state_update_payload(game_state) when is_map(game_state) do
    {:ok, game_state, 0, nil, nil}
  end

  defp normalize_state_update_payload(_payload), do: :error

  defp stale_game_snapshot?(state, room_code, game_instance_id, state_revision)
       when is_binary(game_instance_id) and is_integer(state_revision) do
    case {Map.get(state.active_game_instances, room_code),
          Map.get(state.game_snapshot_cursors, room_code)} do
      {active_instance_id, _cursor} when active_instance_id != game_instance_id ->
        true

      {^game_instance_id, {^game_instance_id, accepted_revision}} ->
        state_revision <= accepted_revision

      _ ->
        false
    end
  end

  defp stale_game_snapshot?(_state, _room_code, _game_instance_id, _state_revision), do: false

  defp put_game_snapshot_cursor(state, room_code, game_instance_id, state_revision)
       when is_binary(game_instance_id) and is_integer(state_revision) do
    %{
      state
      | game_snapshot_cursors:
          Map.put(state.game_snapshot_cursors, room_code, {game_instance_id, state_revision})
    }
  end

  defp put_game_snapshot_cursor(state, _room_code, _game_instance_id, _state_revision), do: state

  defp put_active_game_instance(state, room_code, %{game_instance_id: instance_id}) do
    %{
      state
      | active_game_instances: Map.put(state.active_game_instances, room_code, instance_id),
        game_snapshot_cursors: Map.delete(state.game_snapshot_cursors, room_code)
    }
  end

  defp disconnect_player(%State{} = state, %Room{} = room, room_code, user_id) do
    if Positions.has_player?(room, user_id) do
      updated_room =
        %Room{room | last_activity: DateTime.utc_now()}
        |> mark_disconnected(room_code, user_id)

      updated_state =
        %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}
        |> note_finished_absence(updated_room, user_id)

      {:ok, updated_room, updated_state}
    else
      {:error, :player_not_in_room, state}
    end
  end

  # Nothing is at stake in a finished room, so the seat is left alone. But the
  # others may be waiting on this player for a rematch: if they are still gone
  # after the hiccup window, treat it as having left. The token belongs to this
  # absence: coming back drops it (`register_channel_pid/4`), so the timer of an
  # earlier absence cannot cut a later one short.
  defp note_finished_absence(%State{} = state, %Room{status: :finished, code: code}, user_id) do
    token = make_ref()

    Process.send_after(
      self(),
      {:finished_absence, code, user_id, token},
      Lifecycle.config(:hiccup_timeout_ms)
    )

    %State{state | finished_absences: Map.put(state.finished_absences, {code, user_id}, token)}
  end

  defp note_finished_absence(%State{} = state, %Room{}, _user_id), do: state

  # A player who dropped during the game gets no disconnect in the finished
  # room to start their window, so it starts when the game ends.
  defp note_absences_at_game_over(%State{} = state, %Room{code: room_code} = room) do
    # A seat the cascade already handed to a substitute keeps its player in
    # `reserved_for`, not `user_id`; game over cancels the timer that would
    # have released it.
    room.seats
    |> Enum.map(fn {_position, seat} ->
      if seat.occupant_type == :human, do: seat.user_id, else: seat.reserved_for
    end)
    |> Enum.filter(&(is_binary(&1) and not channel_alive?(state, room_code, &1)))
    |> Enum.reduce(state, &note_finished_absence(&2, room, &1))
  end

  @doc false
  # Multiplayer games use the disconnect cascade. A solo game holds its only
  # human seat without a deadline so switching apps cannot surrender it. A
  # `:finished` room only records the activity.
  defp mark_disconnected(%Room{status: :playing, pace: :own} = room, room_code, user_id),
    do: hold_seat(room, room_code, user_id)

  defp mark_disconnected(
         %Room{status: :playing, config: %Config{solo: true}} = room,
         room_code,
         user_id
       ),
       do: hold_seat(room, room_code, user_id)

  defp mark_disconnected(%Room{status: :playing} = room, room_code, user_id),
    do: start_hiccup_cascade(room, room_code, user_id)

  defp mark_disconnected(%Room{status: status} = room, room_code, user_id)
       when status in [:waiting, :ready],
       do: hold_seat(room, room_code, user_id)

  defp mark_disconnected(%Room{} = room, _room_code, _user_id), do: room

  @doc false
  # Holds the seat of a player whose last game channel closed in a waiting
  # room (R18), or the human seat in a solo game: the seat becomes
  # `:reconnecting` with no phase timer, so no bot ever takes it until the
  # reclaim (`handle_seat_reconnection/6`). A seat that is not `:connected` is
  # left as it is.
  defp hold_seat(%Room{} = room, room_code, user_id) do
    position = Positions.get_position(room, user_id)
    seat = Map.get(room.seats, position)

    case seat && Seat.disconnect(seat) do
      {:ok, held_seat} ->
        broadcast_player_reconnecting(room_code, user_id, position)

        updated =
          room
          |> Map.put(:seats, Map.put(room.seats, position, held_seat))
          |> reset_readiness()
          |> bump_seat_lifecycle_revision()

        broadcast_readiness(updated)
        updated

      _ ->
        room
    end
  end

  @doc false
  @spec broadcast_player_reconnecting(String.t(), String.t(), Positions.position()) :: :ok
  defp broadcast_player_reconnecting(room_code, user_id, position) do
    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "game:#{room_code}",
      {:player_reconnecting, %{user_id: user_id, position: position}}
    )
  end

  # Watch membership outlives a transport, but only for the existing reconnect
  # grace window. Timer references and monitored PIDs fence reordered cleanup.
  defp schedule_spectator_expiry(%State{} = state, room_code, user_id) do
    state = cancel_spectator_expiry(state, room_code, user_id)

    ref =
      :erlang.start_timer(
        Lifecycle.config(:grace_timeout_ms),
        self(),
        {:spectator_expired, room_code, user_id}
      )

    %{state | spectator_timers: Map.put(state.spectator_timers, {room_code, user_id}, ref)}
  end

  defp cancel_spectator_expiry(%State{} = state, room_code, user_id) do
    {ref, timers} = Map.pop(state.spectator_timers, {room_code, user_id})
    if ref, do: :erlang.cancel_timer(ref)
    %{state | spectator_timers: timers}
  end

  defp unregister_spectator_pid(%State{} = state, room_code, user_id, pid) do
    refs =
      for {ref, registration} <- state.spectator_monitors,
          registration == {room_code, user_id, pid},
          do: ref

    if refs == [] do
      {:not_registered, state}
    else
      Enum.each(refs, &Process.demonitor(&1, [:flush]))
      state = %{state | spectator_monitors: Map.drop(state.spectator_monitors, refs)}

      remaining? =
        Enum.any?(state.spectator_monitors, fn {_, {code, id, _}} ->
          code == room_code and id == user_id
        end)

      if remaining?,
        do: {:channels_remaining, state},
        else: {:last_channel_closed, schedule_spectator_expiry(state, room_code, user_id)}
    end
  end

  defp drop_spectator_connections(%State{} = state, room_code, user_id) do
    refs =
      for {ref, {code, id, pid}} <- state.spectator_monitors,
          code == room_code and id == user_id do
        Process.demonitor(ref, [:flush])
        send(pid, {:force_disconnect, :left})
        ref
      end

    state = %{state | spectator_monitors: Map.drop(state.spectator_monitors, refs)}
    cancel_spectator_expiry(state, room_code, user_id)
  end

  defp end_spectating(%State{} = state, user_id, claimed_room \\ nil) do
    case state.spectator_rooms[user_id] do
      nil ->
        state

      room_code ->
        state = drop_spectator_connections(state, room_code, user_id)
        room = state.rooms[room_code]
        room = %{room | spectator_ids: List.delete(room.spectator_ids, user_id)}
        # A same-room promotion publishes one completed seat/membership snapshot,
        # not an intermediate watch removal with the same revision as the claim.
        room =
          if room_code == claimed_room,
            do: room,
            else: room |> bump_seat_lifecycle_revision() |> touch_last_activity()

        state = %{
          state
          | rooms: Map.put(state.rooms, room_code, room),
            spectator_rooms: Map.delete(state.spectator_rooms, user_id)
        }

        unless room_code == claimed_room do
          broadcast_room(room_code, room)
          broadcast_lobby_event({:room_updated, room})
          broadcast_seat_lifecycle(room)
        end

        state
    end
  end

  defp register_channel_pid(%State{} = state, room_code, user_id, pid) do
    key = {room_code, user_id}
    existing = Map.get(state.channel_pids, key, MapSet.new())

    if MapSet.member?(existing, pid) do
      state
    else
      ref = Process.monitor(pid)

      %State{
        state
        | channel_pids: Map.put(state.channel_pids, key, MapSet.put(existing, pid)),
          channel_monitors: Map.put(state.channel_monitors, ref, {room_code, user_id, pid}),
          finished_absences: Map.delete(state.finished_absences, key)
      }
    end
  end

  defp unregister_channel_pid(%State{} = state, room_code, user_id, pid) do
    key = {room_code, user_id}
    existing = Map.get(state.channel_pids, key, MapSet.new())

    if not MapSet.member?(existing, pid) do
      {:not_registered, state}
    else
      refs_to_remove =
        state.channel_monitors
        |> Enum.filter(fn {_ref, {registered_room_code, registered_user_id, registered_pid}} ->
          registered_room_code == room_code and registered_user_id == user_id and
            registered_pid == pid
        end)
        |> Enum.map(&elem(&1, 0))

      Enum.each(refs_to_remove, &Process.demonitor(&1, [:flush]))

      remaining = MapSet.delete(existing, pid)

      channel_pids =
        if MapSet.size(remaining) == 0 do
          Map.delete(state.channel_pids, key)
        else
          Map.put(state.channel_pids, key, remaining)
        end

      channel_monitors = Map.drop(state.channel_monitors, refs_to_remove)

      result = if MapSet.size(remaining) == 0, do: :last_channel_closed, else: :channels_remaining
      {result, %State{state | channel_pids: channel_pids, channel_monitors: channel_monitors}}
    end
  end

  defp disconnect_after_last_channel(state, room_code, user_id) do
    case Map.get(state.rooms, room_code) do
      %Room{} = room ->
        case disconnect_player(state, room, room_code, user_id) do
          {:ok, updated, next} ->
            broadcast_room(room_code, updated)
            broadcast_lobby_event({:room_updated, updated})
            broadcast_seat_lifecycle(updated)
            next

          _ ->
            state
        end

      nil ->
        state
    end
  end

  defp drop_room_channel_registrations(%State{} = state, room_code) do
    refs_to_remove =
      state.channel_monitors
      |> Enum.filter(fn {_ref, {registered_room_code, _user_id, _pid}} ->
        registered_room_code == room_code
      end)
      |> Enum.map(&elem(&1, 0))

    Enum.each(refs_to_remove, &Process.demonitor(&1, [:flush]))

    channel_pids =
      state.channel_pids
      |> Enum.reject(fn {{registered_room_code, _user_id}, _pids} ->
        registered_room_code == room_code
      end)
      |> Map.new()

    %State{
      state
      | channel_pids: channel_pids,
        channel_monitors: Map.drop(state.channel_monitors, refs_to_remove)
    }
  end

  defp teardown_state(%State{} = state) do
    Enum.each(state.rooms, fn {room_code, room} ->
      maybe_cancel_turn_timer(room)
      cancel_all_phase_timers(room)
      terminate_room_bots(room)
      _ = GameSupervisor.stop_game(room_code)
    end)

    Enum.each(Map.keys(state.channel_monitors), &Process.demonitor(&1, [:flush]))
    Enum.each(Map.keys(state.spectator_monitors), &Process.demonitor(&1, [:flush]))
    Enum.each(Map.values(state.spectator_timers), &:erlang.cancel_timer/1)

    Enum.each(state.subscribed_game_topics, fn room_code ->
      GameAdapter.unsubscribe(room_code)
    end)

    %State{}
  end

  defp subscribe_to_game_topic(%State{} = state, room_code) do
    if MapSet.member?(state.subscribed_game_topics, room_code) do
      state
    else
      :ok = GameAdapter.subscribe(room_code)
      %{state | subscribed_game_topics: MapSet.put(state.subscribed_game_topics, room_code)}
    end
  end

  defp unsubscribe_from_game_topic(%State{} = state, room_code) do
    if MapSet.member?(state.subscribed_game_topics, room_code) do
      :ok = GameAdapter.unsubscribe(room_code)
      %{state | subscribed_game_topics: MapSet.delete(state.subscribed_game_topics, room_code)}
    else
      state
    end
  end

  defp reconcile_turn_timer_for_current_state(%Room{} = room, room_code, %State{} = state) do
    case GameAdapter.get_state(room_code) do
      {:ok, game_state} ->
        reconcile_turn_timer(room, room_code, game_state, 0, state)

      {:error, _reason} ->
        {room, state}
    end
  end

  defp reconcile_turn_timer(
         %Room{} = room,
         room_code,
         game_state,
         transition_delay_ms,
         %State{} = state
       ) do
    current_window = current_action_window(room, game_state)

    case {room.turn_timer, current_window} do
      {%{key: key}, {:ok, key, _scope, _actor_position, _phase, _duration_ms}} ->
        {room, state}

      {%{}, :none} ->
        {cancel_active_turn_timer(room, room_code, :acted), state}

      {%{}, {:ok, key, scope, actor_position, phase, duration_ms}} ->
        room =
          room
          |> cancel_active_turn_timer(room_code, :acted)
          |> start_turn_timer(
            room_code,
            key,
            scope,
            actor_position,
            phase,
            duration_ms,
            transition_delay_ms
          )

        {room, state}

      {nil, :none} ->
        {room, state}

      {nil, {:ok, key, scope, actor_position, phase, duration_ms}} ->
        room =
          start_turn_timer(
            room,
            room_code,
            key,
            scope,
            actor_position,
            phase,
            duration_ms,
            transition_delay_ms
          )

        {room, state}
    end
  end

  defp maybe_schedule_sweep(
         %Room{status: :playing, pace: :quick},
         room_code,
         game_state,
         transition_delay_ms
       ) do
    if Play.settled_play(game_state) do
      delay_ms = max(transition_delay_ms, sweep_delay_ms())
      schedule_sweep_play(room_code, length(game_state.events), 3, delay_ms)
    end
  end

  defp maybe_schedule_sweep(_room, _room_code, _game_state, _transition_delay_ms), do: nil

  defp schedule_sweep_play(room_code, event_seq, retries, delay_ms) do
    Process.send_after(self(), {:sweep_play, room_code, event_seq, retries}, delay_ms)
  end

  defp sweep_delay_ms, do: Lifecycle.config(:sweep_trick_delay_ms)

  defp current_action_window(%Room{} = room, game_state) do
    if room.status != :playing or room.pace == :own or single_player_room?(room) or
         Play.settled_play(game_state) != nil do
      :none
    else
      phase = Map.get(game_state, :phase)
      event_seq = length(Map.get(game_state, :events, []))

      cond do
        phase == :dealer_selection and all_human_table?(room) ->
          case first_connected_human_position(room) do
            nil ->
              :none

            actor_position ->
              {:ok, {:room, :dealer_selection, event_seq}, :room, actor_position,
               :dealer_selection, Lifecycle.config(:turn_timer_play_ms)}
          end

        phase in [:bidding, :declaring, :playing, :second_deal] ->
          position = Map.get(game_state, :current_turn)
          seat = position && Map.get(room.seats, position)
          actions = if position, do: Engine.legal_actions(game_state, position), else: []

          if seat && seat.occupant_type == :human &&
               seat.status in [:connected, :reconnecting] && actions != [] do
            {:ok, {:seat, position, phase, event_seq}, :seat, position, phase,
             turn_timer_duration_ms(phase)}
          else
            :none
          end

        true ->
          :none
      end
    end
  end

  defp turn_timer_duration_ms(:bidding), do: Lifecycle.config(:turn_timer_bid_ms)
  defp turn_timer_duration_ms(_phase), do: Lifecycle.config(:turn_timer_play_ms)

  defp start_turn_timer(
         %Room{} = room,
         room_code,
         key,
         scope,
         actor_position,
         phase,
         duration_ms,
         transition_delay_ms
       ) do
    timer =
      TurnTimer.start_timer(
        self(),
        room_code,
        key,
        scope,
        actor_position,
        phase,
        duration_ms,
        transition_delay_ms
      )

    broadcast_game_event(room_code, {:turn_timer_started, turn_timer_payload(timer)})

    %{room | turn_timer: timer}
  end

  defp maybe_cancel_turn_timer(%Room{turn_timer: nil} = room), do: room

  defp maybe_cancel_turn_timer(%Room{} = room) do
    TurnTimer.cancel_timer(room.turn_timer)
    %{room | turn_timer: nil}
  end

  defp cancel_active_turn_timer(%Room{} = room, room_code, reason) do
    timer = room.turn_timer
    TurnTimer.cancel_timer(timer)

    broadcast_game_event(
      room_code,
      {:turn_timer_cancelled, turn_timer_cancelled_payload(timer, reason)}
    )

    %{room | turn_timer: nil}
  end

  defp extend_active_turn_timer(%Room{} = room, room_code, position) do
    case room.turn_timer do
      %{scope: :seat, actor_position: ^position} = timer ->
        duration_ms =
          TurnTimer.remaining_ms(timer) + Lifecycle.config(:reconnect_turn_extension_ms)

        room
        |> cancel_active_turn_timer(room_code, :disconnected)
        |> start_turn_timer(
          room_code,
          timer.key,
          :seat,
          position,
          timer.phase,
          duration_ms,
          0
        )
        # Still the same turn: it opened when it first did.
        |> put_in([Access.key(:turn_timer), :opened_at_mono], timer.opened_at_mono)

      _ ->
        room
    end
  end

  defp handle_turn_timer_expired(%Room{} = room, room_code, timer_id, key, %State{} = state) do
    case room.turn_timer do
      %{
        timer_id: ^timer_id,
        key: ^key,
        scope: scope,
        actor_position: actor_position,
        phase: phase
      } = timer ->
        cleared_room = %{room | turn_timer: nil}
        cleared_state = %{state | rooms: Map.put(state.rooms, room_code, cleared_room)}

        with {:ok, game_state} <- GameAdapter.get_state(room_code),
             {:ok, ^key, ^scope, ^actor_position, _current_phase, _duration_ms} <-
               current_action_window(cleared_room, game_state),
             {:ok, legal_actions} <- GameAdapter.get_legal_actions(room_code, actor_position),
             true <- legal_actions != [],
             view = SeatView.for_seat(game_state, actor_position),
             {:ok, action, _reasoning} <- TimeoutStrategy.pick_action(legal_actions, view),
             resolved_action <- BotBrain.resolve_action(action, game_state, actor_position),
             {:ok, _new_state} <-
               GameAdapter.apply_action(room_code, actor_position, resolved_action) do
          {updated_room, incremented?} =
            maybe_increment_timeout_counter(cleared_room, scope, actor_position)

          if incremented? do
            Stats.record_seat_event(
              updated_room.seats[actor_position].user_id,
              room_code,
              "timeout",
              TurnTimer.elapsed_ms(timer)
            )
          end

          broadcast_game_event(
            room_code,
            {:turn_auto_played,
             turn_auto_played_payload(scope, actor_position, phase, resolved_action)}
          )

          updated_state = %{
            cleared_state
            | rooms: Map.put(cleared_state.rooms, room_code, updated_room)
          }

          if incremented? and timeout_threshold_reached?(updated_room, actor_position) do
            maybe_force_disconnect(updated_room, room_code, actor_position, updated_state)
          else
            {updated_room, updated_state}
          end
        else
          {:error, {:not_your_turn, _}} ->
            {cleared_room, cleared_state}

          {:error, :game_already_complete} ->
            {cleared_room, cleared_state}

          {:error, :not_found} ->
            {cleared_room, cleared_state}

          false ->
            {cleared_room, cleared_state}

          other ->
            Logger.debug("Discarding stale turn timeout for #{room_code}: #{inspect(other)}")
            {cleared_room, cleared_state}
        end

      _ ->
        {room, state}
    end
  end

  # Time per turn for the beta report, on the turns the server clocks.
  defp record_timed_turn(
         %Room{turn_timer: %{scope: :seat, actor_position: position} = timer} = room,
         user_id,
         position
       ),
       do:
         Stats.record_seat_event(
           user_id,
           room.code,
           "turn",
           TurnTimer.elapsed_ms(timer)
         )

  defp record_timed_turn(%Room{}, _user_id, _position), do: :ok

  defp maybe_increment_timeout_counter(%Room{} = room, :seat, actor_position) do
    case Map.get(room.seats, actor_position) do
      %Seat{} = seat ->
        if Seat.connected_human?(seat) do
          count = Map.get(room.consecutive_timeouts, actor_position, 0) + 1

          {%{
             room
             | consecutive_timeouts: Map.put(room.consecutive_timeouts, actor_position, count)
           }, true}
        else
          {room, false}
        end

      _ ->
        {room, false}
    end
  end

  defp maybe_increment_timeout_counter(%Room{} = room, _scope, _actor_position), do: {room, false}

  defp timeout_threshold_reached?(%Room{} = room, actor_position) do
    Map.get(room.consecutive_timeouts, actor_position, 0) >=
      Lifecycle.config(:consecutive_timeout_threshold)
  end

  defp maybe_force_disconnect(%Room{} = room, room_code, actor_position, %State{} = state) do
    case Map.get(room.seats, actor_position) do
      %Seat{} = seat ->
        if Seat.connected_human?(seat) do
          pids =
            state.channel_pids
            |> Map.get({room_code, seat.user_id}, MapSet.new())
            |> MapSet.to_list()

          if pids == [] do
            case disconnect_player(state, room, room_code, seat.user_id) do
              {:ok, updated_room, updated_state} ->
                broadcast_room(room_code, updated_room)
                broadcast_lobby_event({:room_updated, updated_room})
                broadcast_seat_lifecycle(updated_room)
                {updated_room, updated_state}

              {:error, _reason, updated_state} ->
                {room, updated_state}
            end
          else
            Enum.each(pids, &send(&1, {:force_disconnect, :timeout_threshold}))
            {room, state}
          end
        else
          {room, state}
        end

      _ ->
        {room, state}
    end
  end

  defp maybe_reset_timeout_counters_for_new_hand(
         %Room{last_hand_number: nil} = room,
         _game_state
       ),
       do: room

  defp maybe_reset_timeout_counters_for_new_hand(%Room{} = room, game_state) do
    if Map.get(game_state, :hand_number, room.last_hand_number) > room.last_hand_number do
      %{room | consecutive_timeouts: %{}}
    else
      room
    end
  end

  defp reset_timeout_counter(%Room{} = room, nil), do: room

  defp reset_timeout_counter(%Room{} = room, position) do
    %{room | consecutive_timeouts: Map.delete(room.consecutive_timeouts, position)}
  end

  defp all_human_table?(%Room{seats: seats}) when map_size(seats) == 0, do: false

  defp all_human_table?(%Room{seats: seats}) do
    map_size(seats) == @max_players and
      Enum.all?(seats, fn {_position, seat} -> Seat.connected_human?(seat) end)
  end

  defp first_connected_human_position(%Room{seats: seats}) do
    [:north, :east, :south, :west]
    |> Enum.find(fn position ->
      case Map.get(seats, position) do
        %Seat{} = seat -> Seat.connected_human?(seat)
        _ -> false
      end
    end)
  end

  defp serialize_turn_timer(nil), do: nil

  defp serialize_turn_timer(timer) do
    turn_timer_payload(timer)
    |> Map.put(:remaining_ms, TurnTimer.remaining_ms(timer))
  end

  defp turn_timer_payload(timer) do
    %{
      timer_id: timer.timer_id,
      scope: timer.scope,
      position: if(timer.scope == :seat, do: timer.actor_position, else: nil),
      phase: timer.phase,
      duration_ms: timer.duration_ms,
      transition_delay_ms: timer.transition_delay_ms,
      server_time: current_server_time(),
      event_seq: TurnTimer.event_seq(timer.key)
    }
  end

  defp turn_timer_cancelled_payload(timer, reason) do
    %{
      timer_id: timer.timer_id,
      scope: timer.scope,
      position: if(timer.scope == :seat, do: timer.actor_position, else: nil),
      reason: reason
    }
  end

  defp turn_auto_played_payload(scope, actor_position, phase, action) do
    %{
      scope: scope,
      position: if(scope == :seat, do: actor_position, else: nil),
      phase: phase,
      action: serialize_action(action),
      reason: :timeout
    }
  end

  defp serialize_action({:bid, amount}), do: %{type: :bid, amount: amount}
  defp serialize_action(:pass), do: %{type: :pass}
  defp serialize_action({:declare_trump, suit}), do: %{type: :declare_trump, suit: suit}

  defp serialize_action({:play_card, {rank, suit}}),
    do: %{type: :play_card, card: %{rank: rank, suit: suit}}

  defp serialize_action({:select_hand, _cards}), do: %{type: :select_hand}
  defp serialize_action(:select_dealer), do: %{type: :select_dealer}
  defp serialize_action(action), do: %{type: inspect(action)}

  defp current_server_time do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp solo_pace_allowed?(room, user_id) do
    Enum.count(room.seats, fn {_, seat} ->
      seat.occupant_type == :human and seat.user_id == user_id
    end) == 1 and
      Enum.count(room.seats, fn {_, seat} -> seat.occupant_type == :bot end) == 3 and
      Seat.alone_with_bots?(room.seats, user_id)
  end

  defp set_game_pace(%Room{status: status, code: code}, pace)
       when status in [:playing, :finished] do
    case GameAdapter.set_pace(code, pace) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp set_game_pace(_room, _pace), do: :ok

  defp reset_multiplayer_pace(%Room{pace: :own} = room) do
    if Enum.count(room.seats, fn {_, seat} -> seat.occupant_type == :human end) > 1 do
      # A stopped game must not take down the room manager during admission.
      _ = set_game_pace(room, :quick)
      %{room | pace: :quick}
    else
      room
    end
  end

  defp reset_multiplayer_pace(room), do: room

  defp bump_seat_lifecycle_revision(%Room{} = room) do
    %{room | seat_lifecycle_revision: room.seat_lifecycle_revision + 1}
  end

  defp maybe_bump_seat_lifecycle_revision(%Room{} = room, true),
    do: bump_seat_lifecycle_revision(room)

  defp maybe_bump_seat_lifecycle_revision(%Room{} = room, false), do: room

  defp broadcast_seat_lifecycle(%Room{} = room) do
    if room.status == :playing,
      do: PidroServer.GameArchive.track_participants(room.code, room.seats)

    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "game:#{room.code}",
      {:seat_lifecycle, seat_lifecycle_snapshot(room)}
    )
  end

  defp seat_lifecycle_snapshot(%Room{} = room) do
    %{
      room_id: room.id || "#{room.code}:#{DateTime.to_iso8601(room.created_at)}",
      room_code: room.code,
      revision: room.seat_lifecycle_revision,
      owner_id: lifecycle_owner_id(room),
      room_status: Atom.to_string(room.status),
      seats:
        Map.new([:north, :east, :south, :west], fn position ->
          seat = Map.get(room.seats, position, Seat.new_vacant(position))
          {position, serialize_seat_lifecycle(seat)}
        end)
    }
  end

  defp serialize_seat_lifecycle(%Seat{occupant_type: :vacant}) do
    %{status: :vacant, player_id: nil, username: nil, bot_persona: nil, decision: nil}
  end

  defp serialize_seat_lifecycle(%Seat{occupant_type: :human} = seat) do
    status = if seat.status == :connected, do: :normal, else: :reconnecting

    %{
      status: status,
      player_id: seat.user_id,
      username: nil,
      bot_persona: nil,
      decision: nil
    }
  end

  defp serialize_seat_lifecycle(%Seat{reserved_for: player_id})
       when not is_nil(player_id) do
    %{
      status: :bot_substitute,
      player_id: player_id,
      username: nil,
      bot_persona: nil,
      decision: nil
    }
  end

  defp serialize_seat_lifecycle(%Seat{occupant_type: :bot} = seat) do
    decision =
      if seat.decision_id do
        %{id: seat.decision_id, player_id: seat.decision_player_id, player_name: nil}
      end

    %{
      status: :permanent_bot,
      player_id: nil,
      username: if(seat.bot_persona, do: Seat.bot_display_name(seat.bot_persona), else: "Bot"),
      bot_persona: seat.bot_persona,
      decision: decision
    }
  end

  defp lifecycle_owner_id(%Room{} = room) do
    if Enum.any?(room.seats, fn {_position, seat} ->
         Seat.connected_human?(seat) and Seat.owner?(seat) and seat.user_id == room.host_id
       end) do
      room.host_id
    end
  end

  defp broadcast_game_event(room_code, event) do
    Phoenix.PubSub.broadcast_from(PidroServer.PubSub, self(), "game:#{room_code}", event)
  end
end
