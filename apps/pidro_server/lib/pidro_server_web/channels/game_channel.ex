defmodule PidroServerWeb.GameChannel do
  @moduledoc """
  GameChannel handles real-time gameplay for Pidro games.

  Each game has its own channel identified by the room code (e.g., "game:A3F9").
  Players must be authenticated and part of the room to join the channel.

  ## Channel Topics

  * `"game:XXXX"` - Game-specific channel where XXXX is the room code

  ## Incoming Events (from client)

  * `"bid"` - Player makes a bid: `%{"amount" => 8}` or `%{"amount" => "pass"}`
  * `"declare_trump"` - Winner declares trump: `%{"suit" => "hearts"}`
  * `"play_card"` - Player plays a card: `%{"card" => %{"rank" => 14, "suit" => "spades"}}`
  * `"select_hand"` - Dealer selects cards to keep: `%{"cards" => [%{"rank" => 14, "suit" => "hearts"}, ...]}`
  * `"select_dealer"` - Triggers the automatic dealer-selection cut ceremony
  * `"ready"` - Confirm current roster: `%{"room_id" => id, "ready_epoch" => epoch}`.
    Required for every human; success and stale errors include `readiness`.
  * `"rematch"` - Ask for another game in a finished room, same payload and replies as
    `"ready"`. Game over clears readiness and bumps `ready_epoch`; when every human has
    asked, a new game starts in the same room with the same seats.
  * `"talk"` - A seated player at a table with another human sends a face or a
    word: `%{"item" => "coin_heart"}`, one of `@talk_items`. Five per ten
    seconds; errors reply `%{error: "not_seated" | "no_table" | "rate_limited" | "invalid_item"}`
  * `"say"` - A seated player who reads typed talk (an adult account, see
    `PidroServer.Accounts.User.reads_typed?/1`) types to the table: `%{"text" => "Hyvä peli"}`,
    trimmed, 1 to 80 characters, through `PidroServer.Moderation`. Shares the
    talk limit; errors reply `%{error: "not_allowed" | "invalid_text" | "filtered"}`
    or a talk error. Nothing typed is stored outside a report
  * `"report"` - Report a player at the table: `%{"user_id" => id, "reason" =>
    "rude" | "bothering" | "other"}`. The server quotes what they said at this
    table. Errors reply `%{error: "already_reported" | "invalid_report"}`

  ## Outgoing Events (to clients)

  * `"readiness_updated"` - Full versioned roster and readiness snapshot, also included in join replies
  * `"game_state"` - Full game state update: `%{state: game_state, transition_delay_ms: integer()}`
  * `"player_joined"` - New player joined: `%{player_id: id, position: :north}`
  * `"player_left"` - Player left: `%{player_id: id}`
  * `"player_disconnected"` - Player disconnected: `%{user_id: id, position: :north, reason: "left"}`
  * `"player_reconnected"` - Player reconnected: `%{user_id: id, position: position}`
  * `"turn_changed"` - Current player changed: `%{current_player: :north}`
  * `"game_over"` - Game ended: `%{winner: :north_south, scores: %{...}}`
  * `"progression_summary"` - Per-player post-game "what changed" deltas (XP/level,
    achievements, a rated tier move and the partnership run); only this socket's own
    slice (PID-52). A player who joins a finished room gets it again as
    `progression_summary` in the join reply, until a rematch starts (PID-234)
  * `"invite_redeemed"` - A guest claimed a seat through an invite:
    `%{position: :south, user_id: id, username: "anna_123", display_name: "Anna"}`
  * `"seat_moved"` - The host moved a seat: `%{user_id: id, from: :east, to: :west}`;
    the moved player's own channel follows the seat
  * `"player_kicked"` - The host kicked a seat: `%{position: :east, user_id: id}`
  * `"seat_invitation_declined"` - A held seat opened again because its invitee
    answered Not now or sat down with other people elsewhere:
    `%{position: :south, user: %{user_id: id, display_name: "Maija", avatar_url: nil},
    reason: "not_now" | "sat_elsewhere"}`
  * `"kicked"` - Pushed to the kicked player only, then the channel closes with
    reason `{:shutdown, :kicked}`
  * `"talk"` - `%{seat: :north, user_id: id, item: "coin_heart"}`, to everyone on
    the channel except a player either side has blocked; a typed line,
    `%{seat: :north, user_id: id, text: "Hyvä peli"}`, only to seated players
    who read typed talk
  * `"moment"` - `%{id: "start" | "partner_trick" | "game_end"}`, pushed with the
    game state to the seats `PidroServer.Games.Moments` names, never to spectators
  * `"presence_state"` - Presence information (who's online)
  * `"presence_diff"` - Presence changes

  ## Examples

      # Join a game channel
      channel.join("game:A3F9", %{"token" => jwt_token})
        .receive("ok", ({state, position}) => console.log("Joined as", position))

      # Make a bid
      channel.push("bid", {amount: 8})
        .receive("ok", () => console.log("Bid accepted"))
        .receive("error", (error) => console.log("Error:", error))

      # Play a card
      channel.push("play_card", {card: {rank: 14, suit: "spades"}})

      # Listen for state updates
      channel.on("game_state", ({state}) => updateUI(state))
  """

  # Phoenix's default join/action logs render arbitrary client parameters.
  use Phoenix.Channel, log_join: false, log_handle_in: false
  require Logger

  alias Pidro.Game.Engine
  alias PidroServer.{Blocks, Feedback, RateLimit}
  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Moderation
  alias PidroServer.Diagnostics
  alias PidroServer.Games.{GameAdapter, Moments, PresenceAggregator, RoomManager}
  alias PidroServer.Games.Room.Seat
  alias PidroServerWeb.API.RoomJSON
  alias PidroServerWeb.ErrorContract
  alias PidroServerWeb.Presence
  alias PidroServerWeb.Serializers.GameStateSerializer

  # The events that apply an engine move, as `GameAdapter.apply_action/5` logs it.
  @moves ~w(bid pass declare_trump play_card select_hand select_dealer)

  @suit_map %{
    "hearts" => :hearts,
    "diamonds" => :diamonds,
    "clubs" => :clubs,
    "spades" => :spades
  }

  @talk_items ~w(word_nice word_well word_bid word_sorry word_oops word_thanks word_luck
                 word_game word_hello word_noworries coin_thumb coin_heart coin_ha coin_oops
                 coin_wow)

  # Intercept presence_diff, player_ready, and player_reconnected broadcasts to handle them explicitly
  intercept ["presence_diff", "player_ready", "player_reconnected", "player_disconnected", "talk"]

  @doc """
  Authorizes and joins a player or spectator to the game channel.

  Verifies that:
  1. The user is authenticated (user_id in socket assigns)
  2. The room exists
  3. The user is either a player or spectator in the room
  4. The game process exists

  On successful join:
  - Detects and handles reconnection attempts if player was previously disconnected
  - Subscribes to game updates via PubSub
  - Tracks presence with role (player or spectator)
  - Returns initial game state and role-specific information
  """
  @impl true
  def join("game:" <> room_code, params, socket) do
    socket = assign(socket, :client_build, client_build(params))
    user_id = socket.assigns.user_id

    # Subscribe before any room read so lifecycle mutations racing with join
    # are queued and ordered by their snapshot revision.
    :ok = GameAdapter.subscribe(room_code)

    # First, check if this is a reconnection attempt
    with {:ok, room} <- RoomManager.find_room(room_code) do
      # Determine user role (player or spectator)
      role = determine_user_role(room, user_id)

      case role do
        :player ->
          join_player(room_code, user_id, socket)

        :spectator ->
          # Spectators join directly without reconnection logic
          proceed_with_join(room_code, user_id, socket, :new, :spectator)

        :unauthorized ->
          {:error,
           ErrorContract.add(
             %{reason: "not authorized to join this room"},
             :forbidden,
             :action_failed
           )}
      end
    else
      # Not terminal for the app: it retries the join, and the room is there.
      {:error, :room_moving} ->
        {:error,
         ErrorContract.add(
           %{reason: "room is moving, try again"},
           :game_unavailable,
           :action_failed
         )}

      _ ->
        {:error, ErrorContract.add(%{reason: "room not found"}, :room_not_found, :action_failed)}
    end
  end

  defp join_player(room_code, user_id, socket) do
    with :ok <- ensure_player_channel_registered(room_code, user_id, socket.assigns.client_build),
         {:ok, room} <- RoomManager.get_room(room_code) do
      result =
        cond do
          is_reconnection?(room, user_id) ->
            attempt_player_reconnect(room_code, user_id, socket)

          is_permanently_botted?(room, user_id) ->
            {:error,
             ErrorContract.add(
               %{reason: "seat permanently filled by bot"},
               :seat_permanently_filled,
               :action_failed
             )}

          true ->
            proceed_with_join(room_code, user_id, socket, :new, :player)
        end

      cleanup_failed_player_join(room_code, user_id, result)
    else
      {:error, :room_not_found} ->
        cleanup_failed_player_join(
          room_code,
          user_id,
          {:error,
           ErrorContract.add(%{reason: "room not found"}, :room_not_found, :action_failed)}
        )
    end
  end

  defp ensure_player_channel_registered(room_code, user_id, client) do
    case RoomManager.register_game_channel(room_code, user_id, self(), client) do
      :ok -> :ok
      {:error, :room_not_found} -> {:error, :room_not_found}
    end
  end

  defp attempt_player_reconnect(room_code, user_id, socket) do
    case RoomManager.handle_player_reconnect(room_code, user_id) do
      {:ok, updated_room} ->
        Logger.info("Player #{user_id} reconnected to room #{room_code}")

        position = get_player_position(updated_room, user_id)
        send(self(), {:broadcast_reconnection, user_id, position})

        proceed_with_join(room_code, user_id, socket, :reconnect, :player)

      {:error, :seat_permanently_filled} ->
        {:error,
         ErrorContract.add(
           %{reason: "seat permanently filled by bot"},
           :seat_permanently_filled,
           :action_failed
         )}

      {:error, :grace_period_expired} ->
        {:error,
         ErrorContract.add(
           %{reason: "reconnection grace period expired"},
           :grace_period_expired,
           :action_failed
         )}

      {:error, :room_not_found} ->
        {:error, ErrorContract.add(%{reason: "room not found"}, :room_not_found, :action_failed)}

      {:error, reason} ->
        Logger.warning("Reconnection failed for #{user_id}: #{inspect(reason)}")

        {:error,
         ErrorContract.add(
           %{reason: "reconnection failed: #{format_error(reason)}"},
           reason,
           :action_failed
         )}
    end
  end

  defp cleanup_failed_player_join(_room_code, _user_id, {:ok, _reply_data, _socket} = result),
    do: result

  defp cleanup_failed_player_join(room_code, user_id, result) do
    case RoomManager.unregister_game_channel(room_code, user_id, self()) do
      :last_channel_closed -> :ok
      :channels_remaining -> :ok
      :not_registered -> :ok
    end

    result
  end

  # Extract the common join logic into a helper function
  defp proceed_with_join(room_code, user_id, socket, join_type, role) do
    # Already subscribed before join's first room read. Derive the socket position from the
    # same authoritative roster returned to the client, never an earlier room.
    with {:ok, room} <- RoomManager.get_room(room_code),
         true <- user_authorized?(user_id, room, role),
         {:ok, seat_lifecycle} <- RoomManager.get_seat_lifecycle(room_code),
         {:ok, readiness} <- RoomManager.readiness(room_code),
         position = if(role == :player, do: get_player_position(readiness, user_id), else: nil),
         true <- role == :spectator or position != nil,
         :ok <-
           if(role == :player,
             do: RoomManager.register_game_channel(room_code, user_id, self()),
             else: RoomManager.register_spectator_channel(room_code, user_id, self())
           ),
         {:ok, turn_timer} <- RoomManager.get_turn_timer(room_code),
         game_snapshot = fetch_game_snapshot(room_code),
         # A departure can race the snapshot fetch. A queued disconnect cannot
         # retract a join reply, so recheck authority before revealing the hand.
         {:ok, current_room} <- RoomManager.get_room(room_code),
         :ok <- require_playing_snapshot(current_room, game_snapshot),
         true <- current_room.id == room.id and user_authorized?(user_id, current_room, role),
         true <- role == :spectator or get_player_position(current_room, user_id) == position do
      socket =
        socket
        |> assign(:room_code, room_code)
        |> assign(:position, position)
        |> assign(:role, role)
        |> assign(:join_type, join_type)
        |> assign(:blocked_ids, blocked_ids(user_id))
        |> assign(:reads_typed, User.reads_typed?(Auth.get_users_map([user_id])[user_id]))
        |> assign_snapshot_cursor(game_snapshot)

      # Track presence after join
      send(self(), :after_join)

      reply_data = %{
        role: role,
        reconnected: join_type == :reconnect,
        turn_timer: turn_timer,
        readiness: RoomJSON.readiness(readiness),
        seat_lifecycle: seat_lifecycle
      }

      # Add state only if game has started
      reply_data =
        if game_snapshot,
          do: Map.merge(reply_data, client_snapshot_payload(game_snapshot, position)),
          else: Map.put(reply_data, :legal_actions, [])

      # Add position only for players
      reply_data = if position, do: Map.put(reply_data, :position, position), else: reply_data

      # PID-234: a rejoin after game over gets the same summary the push carried.
      reply_data =
        case current_room.post_game_summaries do
          %{^user_id => summary} when role == :player ->
            Map.put(reply_data, :progression_summary, summary)

          _ ->
            reply_data
        end

      Diagnostics.emit(:channel_joined, diagnostic_fields(socket, %{join_type: join_type}))

      if role == :player do
        PidroServer.Stats.record_seat_event(
          user_id,
          room_code,
          "join",
          nil,
          socket.assigns.client_build
        )
      end

      {:ok, reply_data, socket}
    else
      {:error, :game_unavailable} ->
        {:error,
         ErrorContract.add(%{reason: "game_unavailable"}, :game_unavailable, :action_failed)}

      {:error, :room_not_found} ->
        {:error, ErrorContract.add(%{reason: "Room not found"}, :room_not_found, :action_failed)}

      false ->
        {:error,
         ErrorContract.add(%{reason: "Not authorized for this room"}, :forbidden, :action_failed)}

      {:error, :not_spectating} ->
        {:error,
         ErrorContract.add(%{reason: "Not authorized for this room"}, :forbidden, :action_failed)}
    end
  end

  defp fetch_game_snapshot(room_code) do
    case GameAdapter.get_snapshot(room_code) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp require_playing_snapshot(%{status: :playing}, nil), do: {:error, :game_unavailable}
  defp require_playing_snapshot(_room, _snapshot), do: :ok

  @doc """
  Handles game actions from players.

  Supports the following actions:
  - `"bid"` - Make a bid or pass (players only)
  - `"declare_trump"` - Declare trump suit (players only)
  - `"play_card"` - Play a card from hand (players only)
  - `"select_hand"` - Select cards to keep during dealer rob (players only)
  - `"select_dealer"` - Trigger automatic dealer selection (players only)
  - `"ready"` - Signal ready status (players only)
  - `"rematch"` - Ask for another game once this one is over (players only)

  Spectators cannot perform game actions and will receive an error.
  """
  @impl true
  def handle_in(event, params, socket)

  def handle_in("pong", %{"id" => id}, socket) when is_binary(id) do
    RoomManager.connection_activity(socket.assigns.room_code, socket.assigns.user_id, id)
    {:reply, :ok, socket}
  end

  def handle_in("going_background", _params, socket) do
    RoomManager.going_background(socket.assigns.room_code, socket.assigns.user_id)
    {:reply, :ok, socket}
  end

  # The recursive dispatch leaves legacy payload parsing and replies untouched.
  # Only this bounded, server-created context crosses the RoomManager boundary.
  def handle_in(event, params, %{assigns: assigns} = socket)
      when event in ~w(bid pass declare_trump play_card select_hand select_dealer ready rematch set_pace continue_hand open_seat keep_bot close_seat) and
             not is_map_key(assigns, :diagnostic_context) do
    started = System.monotonic_time(:millisecond)
    action_id = if is_map(params), do: Diagnostics.action_id(params["action_id"])
    context = diagnostic_fields(socket, %{action: event, action_id: action_id})
    context = Map.put(context, :expected_turn, expected_turn(params))
    Diagnostics.emit(:action_received, context, :debug)

    try do
      RoomManager.connection_activity(socket.assigns[:room_code], socket.assigns.user_id)

      {:reply, reply, updated} =
        handle_in(event, params, assign(socket, :diagnostic_context, context))

      code =
        case reply do
          {:error, %{error_code: code}} -> code
          _ -> nil
        end

      outcome =
        cond do
          code == "game_unavailable" -> :unknown
          match?({:error, _}, reply) -> :rejected
          true -> :accepted
        end

      # An accepted move already has its line: `action_applied`.
      level =
        cond do
          code == "game_unavailable" -> :warning
          outcome == :accepted and event in @moves -> :debug
          true -> :info
        end

      Diagnostics.emit(
        :action_outcome,
        Map.merge(context, %{
          outcome: outcome,
          error_code: code,
          duration_ms: System.monotonic_time(:millisecond) - started
        }),
        level
      )

      {:reply, reply, %{updated | assigns: Map.delete(updated.assigns, :diagnostic_context)}}
    catch
      kind, reason ->
        Diagnostics.emit(
          :action_failed,
          Map.merge(context, %{
            reason: failure_kind(kind, reason),
            duration_ms: System.monotonic_time(:millisecond) - started
          }),
          :error
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Client claims only; never advances the authoritative socket cursor. At most
  # one record per five seconds/channel, and duplicate revisions are coalesced.
  def handle_in(
        "state_received",
        %{"game_instance_id" => instance, "state_revision" => revision},
        socket
      )
      when is_binary(instance) and is_integer(revision) and revision >= 0 do
    now = System.monotonic_time(:millisecond)
    previous = socket.assigns[:diagnostic_ack]

    valid =
      instance == socket.assigns[:game_instance_id] and
        is_integer(socket.assigns[:state_revision]) and revision <= socket.assigns.state_revision

    eligible =
      case previous do
        {^instance, old_revision, at} -> revision > old_revision and now - at >= 5_000
        {_, _, at} -> now - at >= 5_000
        nil -> true
      end

    socket =
      if valid and eligible do
        Diagnostics.emit(:state_received, diagnostic_fields(socket, %{state_revision: revision}))
        assign(socket, :diagnostic_ack, {instance, revision, now})
      else
        socket
      end

    {:reply, :ok, socket}
  end

  def handle_in("state_received", _params, socket), do: {:reply, :ok, socket}

  def handle_in("set_pace", %{"pace" => pace}, socket) when pace in ["quick", "own"] do
    pace = if pace == "own", do: :own, else: :quick

    case RoomManager.set_pace(socket.assigns.room_code, socket.assigns.user_id, pace) do
      {:ok, pace} -> {:reply, {:ok, %{pace: Atom.to_string(pace)}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("set_pace", _params, socket),
    do: {:reply, {:error, %{reason: "invalid_pace"}}, socket}

  def handle_in("continue_hand", _params, socket) do
    :ok = RoomManager.continue_hand(socket.assigns.room_code, socket.assigns.user_id)
    {:reply, :ok, socket}
  end

  def handle_in("bid", %{"amount" => "pass"}, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot make bids"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      apply_game_action(socket, :pass)
    end
  end

  def handle_in("pass", _params, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot make bids"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      apply_game_action(socket, :pass)
    end
  end

  def handle_in("bid", %{"amount" => amount}, socket) when is_integer(amount) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot make bids"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      apply_game_action(socket, {:bid, amount})
    end
  end

  def handle_in("bid", %{"amount" => amount}, socket) when is_binary(amount) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot make bids"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      case Integer.parse(amount) do
        {num, _} ->
          apply_game_action(socket, {:bid, num})

        :error ->
          {:reply,
           {:error,
            ErrorContract.add(
              %{reason: "Invalid bid amount"},
              :invalid_bid_amount,
              :action_failed
            )}, socket}
      end
    end
  end

  def handle_in("declare_trump", %{"suit" => suit}, socket) when is_binary(suit) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot declare trump"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      case parse_suit(suit) do
        {:ok, suit_atom} ->
          apply_game_action(socket, {:declare_trump, suit_atom})

        :error ->
          {:reply,
           {:error, ErrorContract.add(%{reason: "invalid suit"}, :invalid_suit, :action_failed)},
           socket}
      end
    end
  end

  def handle_in("play_card", %{"card" => %{"rank" => rank, "suit" => suit}}, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot play cards"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      with {:ok, suit_atom} <- parse_suit(suit),
           true <- is_integer(rank) do
        card = {rank, suit_atom}
        apply_game_action(socket, {:play_card, card})
      else
        false ->
          {:reply,
           {:error,
            ErrorContract.add(%{reason: "invalid card rank"}, :invalid_card, :action_failed)},
           socket}

        :error ->
          {:reply,
           {:error,
            ErrorContract.add(%{reason: "invalid card suit"}, :invalid_card, :action_failed)},
           socket}
      end
    end
  end

  def handle_in("select_hand", %{"cards" => cards}, socket) when is_list(cards) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot select hand"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      case parse_cards(cards) do
        {:ok, card_tuples} ->
          apply_game_action(socket, {:select_hand, card_tuples})

        {:error, reason} ->
          {:reply, {:error, ErrorContract.add(%{reason: reason}, :invalid_card, :action_failed)},
           socket}
      end
    end
  end

  def handle_in("select_dealer", _params, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot select dealer"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      apply_game_action(socket, :select_dealer)
    end
  end

  def handle_in("ready", %{"room_id" => room_id, "ready_epoch" => epoch}, socket)
      when is_integer(epoch) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot signal ready"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      case RoomManager.confirm_ready(
             socket.assigns.room_code,
             room_id,
             socket.assigns.user_id,
             self(),
             epoch
           ) do
        {:ok, readiness} ->
          {:reply, {:ok, %{readiness: RoomJSON.readiness(readiness)}}, socket}

        {:error, :room_not_found, nil} ->
          {:reply,
           {:error,
            ErrorContract.add(%{reason: "room_not_found"}, :room_not_found, :action_failed)},
           socket}

        {:error, reason, readiness} ->
          {:reply,
           {:error,
            ErrorContract.add(
              %{reason: Atom.to_string(reason), readiness: RoomJSON.readiness(readiness)},
              reason,
              :action_failed
            )}, socket}
      end
    end
  end

  def handle_in("ready", _params, socket),
    do:
      {:reply,
       {:error,
        ErrorContract.add(%{reason: "invalid_readiness"}, :invalid_readiness, :action_failed)},
       socket}

  # A rematch is the ready check on a finished room, so the payload and replies
  # match "ready". The client says only "again"; the server derives the next
  # game from the room.
  def handle_in("rematch", %{"room_id" => room_id, "ready_epoch" => epoch}, socket)
      when is_integer(epoch) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot ask for a rematch"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      case RoomManager.confirm_rematch(
             socket.assigns.room_code,
             room_id,
             socket.assigns.user_id,
             self(),
             epoch
           ) do
        {:ok, readiness} ->
          {:reply, {:ok, %{readiness: RoomJSON.readiness(readiness)}}, socket}

        {:error, :room_not_found, nil} ->
          {:reply,
           {:error,
            ErrorContract.add(%{reason: "room_not_found"}, :room_not_found, :action_failed)},
           socket}

        {:error, reason, readiness} ->
          {:reply,
           {:error,
            ErrorContract.add(
              %{reason: Atom.to_string(reason), readiness: RoomJSON.readiness(readiness)},
              reason,
              :action_failed
            )}, socket}
      end
    end
  end

  def handle_in("rematch", _params, socket),
    do:
      {:reply,
       {:error,
        ErrorContract.add(%{reason: "invalid_readiness"}, :invalid_readiness, :action_failed)},
       socket}

  def handle_in(event, %{"position" => position} = params, socket)
      when event in ["open_seat", "keep_bot"] do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot manage seats"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      case parse_position(position) do
        {:ok, pos_atom} ->
          decision_id = Map.get(params, "decision_id")

          result =
            if is_binary(decision_id) and byte_size(decision_id) > 0 do
              action = if event == "open_seat", do: :open_seat, else: :keep_bot

              apply(RoomManager, action, [
                socket.assigns.room_code,
                pos_atom,
                socket.assigns.user_id,
                decision_id
              ])
            else
              {:error, :stale_decision}
            end

          case result do
            {:ok, _room} ->
              case RoomManager.get_seat_lifecycle(socket.assigns.room_code) do
                {:ok, snapshot} ->
                  {:reply, {:ok, %{seat_lifecycle: snapshot}}, socket}

                {:error, reason} ->
                  {:reply,
                   {:error,
                    ErrorContract.add(%{reason: format_error(reason)}, reason, :action_failed)},
                   socket}
              end

            {:error, reason} ->
              reply = ErrorContract.add(%{reason: format_error(reason)}, reason, :action_failed)

              reply =
                case RoomManager.get_seat_lifecycle(socket.assigns.room_code) do
                  {:ok, snapshot} -> Map.put(reply, :seat_lifecycle, snapshot)
                  _ -> reply
                end

              {:reply, {:error, reply}, socket}
          end

        :error ->
          {:reply,
           {:error,
            ErrorContract.add(%{reason: "invalid position"}, :invalid_position, :action_failed)},
           socket}
      end
    end
  end

  def handle_in("close_seat", %{"position" => position}, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply,
       {:error,
        ErrorContract.add(
          %{reason: "spectators cannot manage seats"},
          :spectator_action_forbidden,
          :action_failed
        )}, socket}
    else
      case parse_position(position) do
        {:ok, pos_atom} ->
          case RoomManager.close_seat(socket.assigns.room_code, pos_atom, socket.assigns.user_id) do
            {:ok, _room} ->
              {:reply, :ok, socket}

            {:error, reason} ->
              {:reply,
               {:error,
                ErrorContract.add(%{reason: format_error(reason)}, reason, :action_failed)},
               socket}
          end

        :error ->
          {:reply,
           {:error,
            ErrorContract.add(%{reason: "invalid position"}, :invalid_position, :action_failed)},
           socket}
      end
    end
  end

  # The seat and sender come from the socket, never the payload.
  def handle_in("talk", %{"item" => item}, socket) when item in @talk_items do
    case may_talk(socket) do
      :ok ->
        line = %{seat: socket.assigns.position, user_id: socket.assigns.user_id, item: item}
        broadcast!(socket, "talk", line)
        RoomManager.note_talk(socket.assigns.room_code, line)
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: reason}}, socket}
    end
  end

  def handle_in("talk", _params, socket),
    do: {:reply, {:error, %{error: "invalid_item"}}, socket}

  def handle_in("say", %{"text" => text}, socket) when is_binary(text) do
    with {:ok, text} <- typed(String.trim(text), socket.assigns.reads_typed),
         :ok <- may_talk(socket) do
      line = %{seat: socket.assigns.position, user_id: socket.assigns.user_id, text: text}
      broadcast!(socket, "talk", line)
      RoomManager.note_talk(socket.assigns.room_code, line)
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, {:error, %{error: reason}}, socket}
    end
  end

  def handle_in("say", _params, socket),
    do: {:reply, {:error, %{error: "invalid_text"}}, socket}

  # Anyone at the table may report a player there. What they said comes from
  # the room, never from the client.
  def handle_in("report", %{"user_id" => reported_id, "reason" => reason}, socket)
      when is_binary(reported_id) and reason in ~w(rude bothering other) do
    reporter_id = socket.assigns.user_id

    with {:ok, room} <- RoomManager.get_room(socket.assigns.room_code),
         true <- reported_id != reporter_id and at_table?(room, reported_id),
         %{^reporter_id => reporter, ^reported_id => reported} <-
           Auth.get_users_map([reporter_id, reported_id]),
         {:ok, _report} <-
           Feedback.report(
             reporter,
             reported,
             reason,
             game(room, socket),
             said(room, reported_id)
           ) do
      {:reply, :ok, socket}
    else
      {:error, %Ecto.Changeset{errors: [{:user_id, {"already reported", _}} | _]}} ->
        {:reply, {:error, %{error: "already_reported"}}, socket}

      _ ->
        {:reply, {:error, %{error: "invalid_report"}}, socket}
    end
  end

  def handle_in("report", _params, socket),
    do: {:reply, {:error, %{error: "invalid_report"}}, socket}

  def handle_in("get_seat_lifecycle", _params, socket) do
    case RoomManager.get_seat_lifecycle(socket.assigns.room_code) do
      {:ok, snapshot} ->
        {:reply, {:ok, %{seat_lifecycle: snapshot}}, socket}

      {:error, reason} ->
        {:reply,
         {:error, ErrorContract.add(%{reason: format_error(reason)}, reason, :action_failed)},
         socket}
    end
  end

  @doc """
  Handles internal messages and game events.

  Processes the following events:
  - `:state_update` - Game state changed
  - `:game_over` - Game completed
  - `:after_join` - Presence tracking after join
  """
  @impl true
  def handle_info(msg, socket)

  def handle_info({:connection_ping, user_id, payload}, socket) do
    if socket.assigns.user_id == user_id, do: push(socket, "ping", payload)
    {:noreply, socket}
  end

  def handle_info(
        {:state_update, room_code, payload},
        %{assigns: %{room_code: room_code}} = socket
      ) do
    case extract_state_update(payload) do
      {:ok, snapshot} ->
        cond do
          not stale_snapshot?(socket, snapshot) ->
            {:noreply, push_game_state(socket, snapshot)}

          live_game?(socket, snapshot) ->
            Logger.info(
              "Game channel #{room_code} adopts game instance #{snapshot.game_instance_id}"
            )

            {:noreply, push_game_state(socket, snapshot)}

          true ->
            {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:game_over, room_code, winner, scores},
        %{assigns: %{room_code: room_code}} = socket
      ) do
    # RoomManager owns what happens to the room next: a rematch, or closing it.
    push(socket, "game_over", %{winner: winner, scores: scores})

    {:noreply, socket}
  end

  # PID-52: per-player post-game "what changed" summary. The broadcast carries
  # the full `%{user_id => summary}` map; each socket pushes ONLY its own slice
  # (per-socket privacy — clients never see opponents' deltas). A non-participant
  # socket (spectator / bot-only seat) pushes an empty map and never crashes.
  def handle_info(
        {:progression_summary, room_code, summaries},
        %{assigns: %{room_code: room_code, user_id: user_id}} = socket
      ) do
    push(socket, "progression_summary", Map.get(summaries, user_id, %{}))
    {:noreply, socket}
  end

  def handle_info({:turn_timer_started, payload}, socket) do
    push(socket, "turn_timer_started", payload)
    {:noreply, socket}
  end

  def handle_info({:turn_timer_cancelled, payload}, socket) do
    push(socket, "turn_timer_cancelled", payload)
    {:noreply, socket}
  end

  def handle_info({:turn_auto_played, payload}, socket) do
    push(socket, "turn_auto_played", payload)
    {:noreply, socket}
  end

  def handle_info({:force_disconnect, :timeout_threshold}, socket) do
    push(socket, "force_disconnect", %{reason: "timeout_threshold"})
    {:stop, {:shutdown, :timeout_threshold}, socket}
  end

  # Disconnect cascade PubSub events — push to client for UI updates
  def handle_info({:player_reconnecting, %{user_id: user_id, position: position}}, socket) do
    push(socket, "player_reconnecting", %{user_id: user_id, position: position})
    {:noreply, socket}
  end

  def handle_info({:readiness_updated, snapshot}, socket) do
    push(socket, "readiness_updated", RoomJSON.readiness(snapshot))
    {:noreply, socket}
  end

  def handle_info({:player_reconnected, %{user_id: user_id, position: position}}, socket) do
    push(socket, "player_reconnected", %{user_id: user_id, position: position})
    {:noreply, socket}
  end

  def handle_info({:player_reclaimed_seat, %{user_id: user_id, position: position}}, socket) do
    push(socket, "player_reclaimed_seat", %{user_id: user_id, position: position})
    {:noreply, socket}
  end

  def handle_info({:bot_substitute_active, %{position: position, user_id: user_id}}, socket) do
    push(socket, "bot_substitute_active", %{position: position, user_id: user_id})
    {:noreply, socket}
  end

  def handle_info({:seat_permanently_botted, %{position: position}}, socket) do
    push(socket, "seat_permanently_botted", %{position: position})
    {:noreply, socket}
  end

  def handle_info({:seat_lifecycle, snapshot}, socket) do
    push(socket, "seat_lifecycle", PidroServer.Games.SeatLifecycle.with_names(snapshot))
    {:noreply, socket}
  end

  def handle_info({:owner_decision_available, %{position: position, owner_id: owner_id}}, socket) do
    if socket.assigns.user_id == owner_id do
      push(socket, "owner_decision_available", %{position: position, owner_id: owner_id})
    end

    {:noreply, socket}
  end

  def handle_info(
        {:owner_changed, %{new_owner_id: new_owner_id, new_owner_position: new_owner_position}},
        socket
      ) do
    push(socket, "owner_changed", %{
      new_owner_id: new_owner_id,
      new_owner_position: new_owner_position
    })

    {:noreply, socket}
  end

  def handle_info({:substitute_available, %{position: position}}, socket) do
    push(socket, "substitute_available", %{position: position})
    {:noreply, socket}
  end

  def handle_info({:substitute_seat_closed, %{position: position}}, socket) do
    push(socket, "substitute_seat_closed", %{position: position})
    {:noreply, socket}
  end

  def handle_info({:substitute_joined, %{position: position, user_id: user_id}}, socket) do
    push(socket, "substitute_joined", %{position: position, user_id: user_id})
    {:noreply, socket}
  end

  # Invite and host-control events broadcast by the RoomManager on the game topic.
  def handle_info(
        {:invite_redeemed,
         %{
           position: position,
           user_id: user_id,
           username: username,
           display_name: display_name
         }},
        socket
      ) do
    push(socket, "invite_redeemed", %{
      position: position,
      user_id: user_id,
      username: username,
      display_name: display_name
    })

    {:noreply, socket}
  end

  def handle_info({:kicked, %{position: position, user_id: user_id}}, socket) do
    push(socket, "player_kicked", %{position: position, user_id: user_id})
    {:noreply, socket}
  end

  def handle_info({:seat_invitation_declined, %{user_id: user_id} = declined}, socket) do
    push(socket, "seat_invitation_declined", %{
      position: declined.position,
      user: RoomManager.public_user(user_id),
      reason: declined.reason
    })

    {:noreply, socket}
  end

  def handle_info({:seat_moved, %{user_id: user_id, from: from, to: to}}, socket) do
    socket =
      if user_id == socket.assigns.user_id do
        socket = assign(socket, :position, to)
        retrack_presence(socket)
        socket
      else
        socket
      end

    push(socket, "seat_moved", %{user_id: user_id, from: from, to: to})
    {:noreply, socket}
  end

  # The host kicked this player: tell the client, then stop. `room_code` is
  # cleared first so `terminate/2` does not report a disconnect that would hold
  # the (already vacated) seat.
  def handle_info({:force_disconnect, :kicked}, socket) do
    push(socket, "kicked", %{reason: "kicked"})
    {:stop, {:shutdown, :kicked}, assign(socket, :room_code, nil)}
  end

  def handle_info({:force_disconnect, :left}, socket) do
    {:stop, {:shutdown, :left}, assign(socket, :room_code, nil)}
  end

  def handle_info({:broadcast_reconnection, user_id, position}, socket) do
    broadcast_from(socket, "player_reconnected", %{
      user_id: user_id,
      position: position
    })

    {:noreply, socket}
  end

  def handle_info(:after_join, socket) do
    # Phoenix has now installed its channel subscription. Remove only the
    # temporary plain subscription used to queue updates during join reads;
    # unsubscribing the whole topic would also remove Phoenix's fastlane entry.
    :ok = Phoenix.PubSub.unsubscribe_match(socket.pubsub_server, socket.topic, nil)

    user_id = socket.assigns.user_id
    role = socket.assigns.role

    {:ok, _} = Presence.track(socket, user_id, presence_meta(socket))

    activity = if role == :spectator, do: :spectating, else: :playing
    PresenceAggregator.track(user_id, activity)

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  def handle_info(:blocks_changed, socket),
    do: {:noreply, assign(socket, :blocked_ids, Blocks.ids(socket.assigns.user_id))}

  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report(__MODULE__, message)
    {:noreply, socket}
  end

  @spec presence_meta(Phoenix.Socket.t()) :: map()
  defp presence_meta(socket) do
    meta = %{
      online_at: DateTime.utc_now() |> DateTime.to_unix(),
      role: socket.assigns.role
    }

    # Add position only for players
    if socket.assigns.position do
      Map.put(meta, :position, socket.assigns.position)
    else
      meta
    end
  end

  # Re-tracks this socket's presence after its position changed (seat move).
  @spec retrack_presence(Phoenix.Socket.t()) :: :ok
  defp retrack_presence(socket) do
    user_id = socket.assigns.user_id
    :ok = Presence.untrack(socket, user_id)
    {:ok, _} = Presence.track(socket, user_id, presence_meta(socket))
    :ok
  end

  @doc """
  Intercepts outgoing broadcasts.

  This is required when using Presence tracking in channels and for
  custom broadcast messages like player_ready.
  """
  @impl true
  # Blocks were loaded at join, so a talk costs no query per message. A
  # typed line reaches only seated players who read typed talk.
  def handle_out("talk", %{user_id: sender} = msg, socket) do
    blocked? = MapSet.member?(socket.assigns[:blocked_ids] || MapSet.new(), sender)

    reads? =
      not is_map_key(msg, :text) or
        (socket.assigns.role == :player and socket.assigns[:reads_typed] == true)

    if reads? and not blocked?, do: push(socket, "talk", msg)
    {:noreply, socket}
  end

  # The early plain PubSub subscription also delivers non-intercepted events.
  def handle_out(event, msg, socket) do
    push(socket, event, msg)
    {:noreply, socket}
  end

  @doc """
  Handles player or spectator disconnection from the channel.

  Called automatically when a user's channel connection terminates.
  This ensures proper cleanup and notification of other users.

  ## Actions performed:

  1. Extracts room_code, user_id, and role from socket assigns
  2. Notifies RoomManager about the disconnect (players only)
  3. The last spectator channel starts a bounded reconnect grace period
  4. Broadcasts disconnect event to other users in the channel

  ## Disconnect reasons:

  - `:normal` - Clean disconnect (e.g., user closed tab)
  - `:shutdown` - Server shutdown or connection lost
  - `{:shutdown, _}` - Forced disconnect
  - Other reasons are treated as errors
  """
  @impl true
  def terminate(reason, socket) do
    room_code = socket.assigns[:room_code]
    user_id = socket.assigns[:user_id]
    role = socket.assigns[:role]

    Diagnostics.emit(:channel_closed, diagnostic_fields(socket, %{reason: format_reason(reason)}))

    # Only handle disconnect if we have necessary assigns
    if room_code && user_id && role do
      case role do
        :player ->
          Logger.info(
            "Player #{user_id} disconnected from room #{room_code}: #{format_reason(reason)}"
          )

          close = if format_reason(reason) == "left", do: :left, else: :closed

          case RoomManager.unregister_game_channel(room_code, user_id, self(), close) do
            :last_channel_closed ->
              broadcast_from(socket, "player_disconnected", %{
                user_id: user_id,
                position: socket.assigns[:position],
                reason: format_reason(reason),
                grace_period: true
              })

            :channels_remaining ->
              :ok

            :not_registered ->
              :ok
          end

        :spectator ->
          Logger.info(
            "Spectator #{user_id} disconnected from room #{room_code}: #{format_reason(reason)}"
          )

          # A stale transport must not remove a new watch or a promoted player.
          case RoomManager.unregister_spectator_channel(room_code, user_id, self()) do
            :last_channel_closed ->
              broadcast_from(socket, "spectator_left", %{
                user_id: user_id,
                reason: format_reason(reason)
              })

            _ ->
              :ok
          end
      end
    end

    :ok
  end

  ## Private Helpers

  # A talk table has at least two seated humans, and the sender is one of them.
  defp may_talk(%{assigns: %{role: :player, position: position} = assigns})
       when not is_nil(position) do
    user_id = assigns.user_id

    with {:ok, %{seats: %{^position => %{occupant_type: :human, user_id: ^user_id}}} = room} <-
           RoomManager.get_room(assigns.room_code),
         true <- talk_table?(room),
         {:allow, _} <- RateLimit.hit({:talk, user_id}, 10_000, 5) do
      :ok
    else
      {:ok, _room} -> {:error, "not_seated"}
      {:deny, _} -> {:error, "rate_limited"}
      _ -> {:error, "no_table"}
    end
  end

  defp may_talk(_socket), do: {:error, "not_seated"}

  # Followed before the load, so a block made meanwhile is not missed.
  defp blocked_ids(user_id) do
    :ok = Phoenix.PubSub.subscribe(PidroServer.PubSub, Blocks.topic(user_id))
    Blocks.ids(user_id)
  end

  defp typed(_text, false), do: {:error, "not_allowed"}

  # No control or format characters: a newline would forge a line in a
  # report, and a zero-width one would hide a word from the filter.
  defp typed(text, true) do
    cond do
      text == "" or String.length(text) > 80 -> {:error, "invalid_text"}
      text =~ ~r/[\p{Cc}\p{Cf}]/u -> {:error, "invalid_text"}
      Moderation.allowed?(text) -> {:ok, text}
      true -> {:error, "filtered"}
    end
  end

  defp at_table?(room, user_id) do
    Enum.any?(room.seats, fn {_position, seat} -> seat.user_id == user_id end) or
      Enum.any?(room.talk, &(&1.user_id == user_id))
  end

  # The game a report is about: the one being played, else the room.
  defp game(room, socket) do
    %{
      key: socket.assigns[:game_instance_id] || room.id,
      instance: socket.assigns[:game_instance_id],
      room_code: room.code,
      rule_set: room.config.rule_set
    }
  end

  defp said(room, user_id),
    do: room.talk |> Enum.filter(&(&1.user_id == user_id)) |> Enum.reverse()

  defp talk_table?(room),
    do: Enum.count(room.seats, fn {_position, seat} -> seat.occupant_type == :human end) >= 2

  @spec apply_game_action(Phoenix.Socket.t(), term()) ::
          {:reply, :ok | {:error, map()}, Phoenix.Socket.t()}
  defp apply_game_action(socket, action) do
    room_code = socket.assigns.room_code
    position = socket.assigns.position

    case RoomManager.apply_player_action(
           room_code,
           socket.assigns.user_id,
           position,
           action,
           socket.assigns[:diagnostic_context] || %{}
         ) do
      {:ok, _new_state} ->
        # State update is broadcast via PubSub subscription
        {:reply, :ok, socket}

      {:error, {:already_played_for_you, played}} ->
        {:reply,
         {:error,
          ErrorContract.add(
            %{reason: "already_played_for_you", action: played},
            :already_played_for_you,
            :action_failed
          )}, socket}

      {:error, reason} ->
        {:reply,
         {:error, ErrorContract.add(%{reason: format_error(reason)}, reason, :action_failed)},
         socket}
    end
  end

  @spec user_in_room?(String.t(), RoomManager.Room.t()) :: boolean()
  defp user_in_room?(user_id, room) do
    alias PidroServer.Games.Room.Positions
    # Convert user_id to string if it's an integer
    user_id_str = to_string(user_id)
    Positions.has_player?(room, user_id_str)
  end

  @spec user_authorized?(String.t(), RoomManager.Room.t(), atom()) :: boolean()
  defp user_authorized?(user_id, room, :player) do
    user_in_room?(user_id, room)
  end

  defp user_authorized?(user_id, room, :spectator) do
    user_id_str = to_string(user_id)
    Enum.any?(room.spectator_ids, fn id -> to_string(id) == user_id_str end)
  end

  # Phase 3: seat is a permanent bot (reserved_for cleared) but positions
  # still contains the original user_id. Without this guard, the player
  # would slip through as a normal join instead of being rejected.
  @spec is_permanently_botted?(RoomManager.Room.t(), String.t()) :: boolean()
  defp is_permanently_botted?(room, user_id) do
    alias PidroServer.Games.Room.Positions

    case Positions.get_position(room, user_id) do
      nil ->
        false

      position ->
        seat = Map.get(room.seats, position)
        seat != nil && seat.status == :bot_substitute && seat.reserved_for == nil
    end
  end

  @spec is_reconnection?(RoomManager.Room.t(), String.t()) :: boolean()
  defp is_reconnection?(room, user_id) do
    # Check seat-based disconnect cascade:
    # Phase 1 (:reconnecting) — user_id still on seat
    # Phase 2/3 (:bot_substitute with reserved_for) — user_id cleared from seat but reserved_for still set
    Enum.any?(room.seats, fn {_pos, seat} ->
      seat.reserved_for == user_id ||
        (seat.status == :reconnecting && seat.user_id == user_id)
    end)
  end

  @spec determine_user_role(RoomManager.Room.t(), String.t()) ::
          :player | :spectator | :unauthorized
  defp determine_user_role(room, user_id) do
    alias PidroServer.Games.Room.Positions
    user_id_str = to_string(user_id)

    cond do
      Positions.has_player?(room, user_id_str) ->
        :player

      # Player whose seat was taken by a bot still has reserved_for set
      Seat.reserved_for_user?(room.seats, user_id_str) ->
        :player

      # Channel joins/rejoins attach to membership; only explicit REST Join claims seats.
      Enum.any?(room.spectator_ids, fn id -> to_string(id) == user_id_str end) ->
        :spectator

      true ->
        :unauthorized
    end
  end

  @spec get_player_position(map(), String.t()) :: atom() | nil
  defp get_player_position(room, user_id) do
    user_id_str = to_string(user_id)

    Enum.find_value(room.positions, fn {position, id} ->
      if id == user_id_str, do: position
    end)
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp legal_actions_for_state(_state, nil), do: []

  defp legal_actions_for_state(state, position) do
    state
    |> Engine.legal_actions(position)
    |> GameStateSerializer.serialize_legal_actions()
  end

  @position_map %{
    "north" => :north,
    "south" => :south,
    "east" => :east,
    "west" => :west
  }

  @spec parse_position(String.t()) :: {:ok, atom()} | :error
  defp parse_position(position) when is_binary(position) do
    Map.fetch(@position_map, position)
  end

  @spec parse_suit(String.t()) :: {:ok, atom()} | :error
  defp parse_suit(suit) when is_binary(suit) do
    Map.fetch(@suit_map, suit)
  end

  @spec parse_cards(list()) :: {:ok, list({integer(), atom()})} | {:error, String.t()}
  defp parse_cards(cards) when is_list(cards) do
    Enum.reduce_while(cards, {:ok, []}, fn
      %{"rank" => rank, "suit" => suit}, {:ok, acc} when is_integer(rank) ->
        case parse_suit(suit) do
          {:ok, suit_atom} -> {:cont, {:ok, [{rank, suit_atom} | acc]}}
          :error -> {:halt, {:error, "invalid card suit"}}
        end

      _, _acc ->
        {:halt, {:error, "invalid card payload"}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  @spec format_reason(term()) :: String.t()
  defp format_reason(:normal), do: "left"
  defp format_reason({:shutdown, :left}), do: "left"
  defp format_reason({:shutdown, :timeout_threshold}), do: "timeout"
  defp format_reason({:shutdown, :kicked}), do: "kicked"
  defp format_reason(:shutdown), do: "connection_lost"
  defp format_reason({:shutdown, _}), do: "connection_lost"
  defp format_reason(_), do: "error"

  defp extract_state_update(%{state: game_state, transition_delay_ms: delay_ms} = snapshot)
       when is_map(game_state) and is_integer(delay_ms),
       do: {:ok, snapshot}

  defp extract_state_update(%{state: game_state}) when is_map(game_state),
    do: {:ok, %{state: game_state, transition_delay_ms: 0}}

  defp extract_state_update(game_state) when is_map(game_state),
    do: {:ok, %{state: game_state, transition_delay_ms: 0}}

  defp extract_state_update(_payload), do: :error

  defp client_snapshot_payload(snapshot, position) do
    %{
      state: GameStateSerializer.serialize(snapshot.state, position),
      turn_event_seq: length(snapshot.state.events),
      legal_actions: legal_actions_for_state(snapshot.state, position),
      transition_delay_ms: Map.get(snapshot, :transition_delay_ms, 0)
    }
    |> Map.merge(
      Map.take(snapshot, [
        :game_instance_id,
        :state_revision,
        :server_time_ms
      ])
    )
    |> Map.put(:presentation, client_presentation(Map.get(snapshot, :presentation), position))
  end

  defp client_presentation(nil, _position), do: nil

  defp client_presentation(presentation, position) do
    dealer_rob = Map.get(presentation, :dealer_rob)

    %{
      dealer_selection: Map.get(presentation, :dealer_selection),
      dealer_rob: client_dealer_rob_presentation(dealer_rob, position)
    }
  end

  defp client_dealer_rob_presentation(nil, _position), do: nil

  defp client_dealer_rob_presentation(presentation, position) do
    public = Map.take(presentation, [:dealer, :automatic, :started_at_ms, :ends_at_ms])

    if position == presentation.dealer do
      Map.merge(public, %{
        pool: GameStateSerializer.serialize_cards(presentation.pool),
        kept: GameStateSerializer.serialize_cards(presentation.kept),
        discarded: GameStateSerializer.serialize_cards(presentation.discarded)
      })
    else
      public
    end
  end

  defp stale_snapshot?(socket, snapshot) do
    instance_id = Map.get(snapshot, :game_instance_id)
    revision = Map.get(snapshot, :state_revision)
    accepted_instance_id = socket.assigns[:game_instance_id]

    is_binary(instance_id) and is_integer(revision) and
      is_binary(accepted_instance_id) and
      (instance_id != accepted_instance_id or
         (is_integer(socket.assigns[:state_revision]) and
            revision <= socket.assigns.state_revision))
  end

  defp push_game_state(socket, snapshot) do
    push(socket, "game_state", client_snapshot_payload(snapshot, socket.assigns[:position]))
    socket = push_moments(socket, snapshot)

    Diagnostics.emit(
      :state_pushed,
      diagnostic_fields(socket, Map.take(snapshot, [:game_instance_id, :state_revision])),
      :debug
    )

    assign_snapshot_cursor(socket, snapshot)
  end

  # Only the events this socket has not seen; a new game starts from none.
  # A count is enough because a game only appends events.
  defp push_moments(%{assigns: assigns} = socket, %{state: %{events: events}} = snapshot) do
    seen =
      if snapshot[:game_instance_id] in [nil, assigns[:game_instance_id]],
        do: assigns[:events_seen] || 0,
        else: 0

    for {id, seats} <- events |> Enum.drop(seen) |> Moments.moments(),
        assigns.position in seats,
        do: push(socket, "moment", %{id: id})

    assign(socket, :events_seen, length(events))
  end

  defp push_moments(socket, _snapshot), do: socket

  defp expected_turn(%{"game_instance_id" => id, "turn_event_seq" => seq})
       when is_binary(id) and is_integer(seq) and seq >= 0, do: {id, seq}

  defp expected_turn(params) when is_map(params) do
    if Map.has_key?(params, "turn_event_seq") or Map.has_key?(params, "game_instance_id"),
      do: :invalid
  end

  defp expected_turn(_), do: nil

  defp client_build(params) when is_map(params) do
    %{
      app_version: Diagnostics.token(params["app_version"]),
      app_build:
        if(is_binary(params["app_build"]) and params["app_build"] =~ ~r/\A\d{1,10}\z/,
          do: params["app_build"]
        ),
      platform: Diagnostics.token(params["platform"]),
      reason:
        if(
          params["reason"] in ~w(backgrounded network_lost heartbeat_timeout push_timeout unknown),
          do: params["reason"],
          else: "unknown"
        ),
      network:
        if(params["network"] in ~w(wifi cellular none unknown),
          do: params["network"],
          else: "unknown"
        )
    }
  end

  defp client_build(_), do: %{}

  defp diagnostic_fields(socket, extra) do
    socket.assigns
    |> Map.take([:room_code, :user_id, :game_instance_id])
    |> Map.put(:observed_revision, socket.assigns[:state_revision])
    |> Map.merge(socket.assigns[:client_build] || %{})
    |> Map.merge(extra)
  end

  defp failure_kind(:exit, {:timeout, _}), do: :timeout
  defp failure_kind(_, _), do: :process_failure

  # A rematch replaces the game process, so its snapshots carry an instance this
  # socket has not accepted yet. The registry says which game is live for the
  # room: adopt that one, keep dropping anything from a game that is gone.
  defp live_game?(socket, snapshot) do
    instance_id = Map.get(snapshot, :game_instance_id)

    is_binary(instance_id) and instance_id != socket.assigns[:game_instance_id] and
      match?(%{game_instance_id: ^instance_id}, fetch_game_snapshot(socket.assigns.room_code))
  end

  defp assign_snapshot_cursor(socket, nil) do
    socket
    |> assign(:game_instance_id, nil)
    |> assign(:state_revision, nil)
  end

  defp assign_snapshot_cursor(socket, snapshot) do
    case {Map.get(snapshot, :game_instance_id), Map.get(snapshot, :state_revision)} do
      {instance_id, revision} when is_binary(instance_id) and is_integer(revision) ->
        socket
        |> assign(:game_instance_id, instance_id)
        |> assign(:state_revision, revision)
        |> assign(:events_seen, length(Map.get(snapshot.state, :events, [])))

      _ ->
        socket
    end
  end
end
