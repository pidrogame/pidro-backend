defmodule PidroServerWeb.Dev.GameDetailLive do
  @moduledoc """
  Development UI for detailed game state viewing and interaction.

  This LiveView provides:
  - Real-time game state display
  - Position-based filtering (implemented in DEV-401)
  - Action execution capabilities (implemented in DEV-901 to DEV-904)
  - Raw state inspection with clipboard support (implemented in DEV-801)

  This view is designed for active development and debugging with
  interactive controls.
  """

  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents

  require Logger
  alias PidroServer.Accounts.Auth
  alias PidroServer.Dev.{Event, ReplayController}
  alias PidroServer.Games.Bots.{BotBrain, BotManager, GameHelpers}
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServerWeb.CardComponents

  @human_bot_config %{type: :human, difficulty: :random, delay_ms: 1000, paused: false}

  @impl true
  def mount(%{"code" => room_code}, _session, socket) do
    case RoomManager.get_room(room_code) do
      {:ok, room} ->
        if connected?(socket) do
          # Subscribe to game updates for this specific room
          Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")
          # Subscribe to room updates (for seat assignments, player joins/leaves)
          Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room_code}")
          # Each bot move's reason, on its own topic (see BotBrain.reasoning_topic/1)
          Phoenix.PubSub.subscribe(PidroServer.PubSub, BotBrain.reasoning_topic(room_code))
          Process.send_after(self(), :refresh_bot_status, 2_000)
        end

        # Get initial game state
        game_state = get_game_state(room_code)

        # DEV-901: Fetch legal actions for initial position
        legal_actions = get_legal_actions(room_code, :all)

        # DEV-1106: Initialize bot configuration
        bot_configs = initialize_bot_configs(room_code)

        # DEV-1301: Initialize replay state
        event_count =
          case ReplayController.get_event_count(room_code) do
            {:ok, count} -> count
            {:error, _} -> 0
          end

        events =
          if game_state do
            process_events(game_state.events)
          else
            []
          end

        # Load users for seat management dropdowns
        users = Auth.list_recent_users(20)

        {:ok,
         socket
         |> assign(:room, room)
         |> assign(:room_code, room_code)
         |> assign(:game_state, game_state)
         |> assign(:seats, load_seats(room_code))
         |> assign(:connection_events, [])
         |> assign(:selected_position, :all)
         |> assign(:view_mode, :single)
         |> assign(:legal_actions, legal_actions)
         |> assign(:executing_action, false)
         |> assign(:copy_feedback, false)
         |> assign(:bot_configs, bot_configs)
         |> assign(:bots_paused, all_bots_paused?(bot_configs))
         |> assign(:events, events)
         |> assign(:event_filter_type, nil)
         |> assign(:event_filter_player, nil)
         |> assign(:show_bot_reasoning, true)
         |> assign(:bot_reasons, [])
         |> assign(:show_event_export, false)
         |> assign(:replay_mode, false)
         |> assign(:replay_source, nil)
         |> assign(:replay_index, event_count - 1)
         |> assign(:replay_total_events, event_count)
         |> assign(:replay_playing, false)
         |> assign(:replay_speed, 1000)
         |> assign(:selected_hand_cards, [])
         |> assign(:users, users)
         |> assign(:active_tab, :board)
         |> assign(:page_title, "Game Detail - Dev")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Room not found")
         |> redirect(to: ~p"/admin/games")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case params["tab"] do
        "seats_bots" -> :seats_bots
        "controls" -> :controls
        "activity" -> :activity
        "inspect" -> :inspect
        _ -> :board
      end

    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_info(
        {:state_update, room_code, _payload},
        %{assigns: %{room_code: room_code, replay_mode: true}} = socket
      ),
      do: {:noreply, socket}

  def handle_info(
        {:state_update, room_code, payload},
        %{assigns: %{room_code: room_code}} = socket
      ) do
    case extract_state_update(payload) do
      {:ok, new_state} ->
        legal_actions =
          get_legal_actions(socket.assigns.room_code, socket.assigns.selected_position)

        socket = reconcile_reasons(socket, new_state.events)
        events = process_events(new_state.events, socket.assigns)

        {:noreply,
         socket
         |> assign(:game_state, new_state)
         |> assign(:replay_total_events, length(new_state.events))
         |> assign(:legal_actions, legal_actions)
         |> assign(:events, events)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:bot_reasoning, _, _}, %{assigns: %{replay_mode: true}} = socket),
    do: {:noreply, socket}

  def handle_info(
        {:bot_reasoning, room_code, reasoning},
        %{assigns: %{room_code: room_code}} = socket
      ) do
    socket =
      assign(socket, :bot_reasons, Enum.take(socket.assigns.bot_reasons ++ [reasoning], -200))

    events = process_events(game_events(socket), socket.assigns)
    {:noreply, assign(socket, :events, events)}
  end

  @impl true
  def handle_info({:game_over, _, _, _}, %{assigns: %{replay_mode: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:game_over, _room_code, _winner, _scores}, socket) do
    # Reload the game state to get the final state
    game_state = get_game_state(socket.assigns.room_code)

    {:noreply,
     socket
     |> assign(:game_state, game_state)
     |> assign(:legal_actions, [])
     |> put_flash(:info, "Game Over!")}
  end

  @impl true
  def handle_info(:refresh_bot_status, %{assigns: %{replay_mode: true}} = socket) do
    Process.send_after(self(), :refresh_bot_status, 2_000)
    {:noreply, socket}
  end

  def handle_info(:refresh_bot_status, socket) do
    # BotManager does not publish pause/resume events. One outstanding timer,
    # no database queries, and no mutation of the operator's configuration draft.
    Process.send_after(self(), :refresh_bot_status, 2_000)

    case initialize_bot_configs(socket.assigns.room_code, :unavailable) do
      :unavailable -> {:noreply, socket}
      configs -> {:noreply, assign(socket, :bots_paused, all_bots_paused?(configs))}
    end
  end

  @impl true
  def handle_info({:turn_timer_started, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:turn_timer_cancelled, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:turn_auto_played, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({tag, _}, %{assigns: %{replay_mode: true}} = socket)
      when tag in [:room_update, :room_updated, :seat_lifecycle],
      do: {:noreply, socket}

  def handle_info({:room_update, room}, socket) do
    Logger.info(
      "LiveView received :room_update - status=#{room.status}, player_count=#{PidroServer.Games.Room.Positions.count(room)}"
    )

    # If room status changed to :playing, fetch initial game state
    socket =
      if room.status == :playing && is_nil(socket.assigns.game_state) do
        Logger.info("Room is :playing and game_state is nil - fetching game state")
        game_state = get_game_state(socket.assigns.room_code)
        Logger.info("Fetched game_state: #{inspect(game_state != nil)}")

        legal_actions =
          get_legal_actions(socket.assigns.room_code, socket.assigns.selected_position)

        socket
        |> assign(:game_state, game_state)
        |> assign(:legal_actions, legal_actions)
      else
        Logger.info(
          "Not fetching game_state - status=#{room.status}, game_state_nil=#{is_nil(socket.assigns.game_state)}"
        )

        socket
      end

    {:noreply, socket |> assign(:room, room) |> refresh_seats()}
  end

  @impl true
  def handle_info({:room_updated, room}, socket) do
    {:noreply, socket |> assign(:room, room) |> refresh_seats()}
  end

  @impl true
  def handle_info({:seat_lifecycle, _snapshot}, socket) do
    {:noreply, refresh_seats(socket)}
  end

  @impl true
  def handle_info({:room_closed}, socket) do
    {:noreply, redirect(socket, to: ~p"/admin/games")}
  end

  @impl true
  def handle_info({:auto_bid_complete, :success}, socket) do
    {:noreply, put_flash(socket, :info, "Auto-bidding completed successfully")}
  end

  @impl true
  def handle_info({:auto_bid_complete, {:error, reason}}, socket) do
    {:noreply, put_flash(socket, :error, "Auto-bidding failed: #{reason}")}
  end

  @impl true
  def handle_info(:replay_tick, socket) do
    if socket.assigns.replay_playing && socket.assigns.replay_mode do
      case ReplayController.step_forward(
             socket.assigns.replay_source,
             socket.assigns.replay_index
           ) do
        {:ok, state, new_index} ->
          # Schedule next tick
          Process.send_after(self(), :replay_tick, socket.assigns.replay_speed)

          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, new_index)
           |> assign(:legal_actions, [])}

        {:error, :at_end} ->
          # Stop playing when we reach the end
          {:noreply, assign(socket, :replay_playing, false)}

        {:error, _reason} ->
          # Stop on error
          {:noreply, assign(socket, :replay_playing, false)}
      end
    else
      {:noreply, socket}
    end
  end

  # This view uses room/state snapshots, not the player-facing notifications
  # or Phoenix channel broadcasts on the same topic.
  @impl true
  def handle_info({tag, _}, socket)
      when tag in [
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
             :readiness_updated,
             :invite_redeemed,
             :seat_moved,
             :kicked,
             :seat_invitation_declined
           ],
      do: {:noreply, socket}

  @impl true
  def handle_info({:progression_summary, _room_code, _summaries}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report_once(__MODULE__, message)
    {:noreply, socket}
  end

  defp game_events(%{assigns: %{replay_mode: true, replay_source: %{events: events}}}),
    do: events

  defp game_events(%{assigns: %{game_state: %{events: events}}}), do: events
  defp game_events(_socket), do: []

  # Keeps the reasons whose move is still in the event log. A reason's move
  # produced the event right after `event_index`, so an undo that removed that
  # event removes the reason too, and earlier reasons stay. A log that starts
  # differently belongs to a new game, whose reasons start over.
  defp reconcile_reasons(socket, new_events) do
    reasons =
      if new_game?(game_events(socket), new_events),
        do: [],
        else: Enum.filter(socket.assigns.bot_reasons, &(&1.event_index < length(new_events)))

    assign(socket, :bot_reasons, reasons)
  end

  defp new_game?([first | _], [other | _]), do: first != other
  defp new_game?(_old_events, _new_events), do: false

  defp extract_state_update(%{state: game_state}) when is_map(game_state), do: {:ok, game_state}
  defp extract_state_update(game_state) when is_map(game_state), do: {:ok, game_state}
  defp extract_state_update(_payload), do: :error

  defp load_seats(room_code) do
    case RoomManager.get_seat_lifecycle(room_code) do
      {:ok, snapshot} -> snapshot.seats
      _ -> %{}
    end
  end

  defp refresh_seats(socket) do
    seats = load_seats(socket.assigns.room_code)

    changes =
      for {position, seat} <- seats,
          old = socket.assigns.seats[position],
          old && old.status != seat.status do
        "#{CardComponents.seat_name(seat)} · #{position}: #{old.status} → #{seat.status}"
      end

    socket
    |> assign(:seats, seats)
    |> assign(:connection_events, Enum.take(changes ++ socket.assigns.connection_events, 50))
  end

  # Hiding buttons is not sufficient: reject stale/forged events outside intervention mode.
  @impl true
  def handle_event(event, _params, socket)
      when event in ~w(assign_seat update_bot_config apply_bot_config toggle_bot_pause toggle_all_bots_pause execute_action play_card submit_hand_selection undo_last_action play_again auto_bid fast_forward continue_hand) and
             (socket.assigns.active_tab != :controls or socket.assigns.replay_mode) do
    {:noreply,
     put_flash(socket, :error, "Enter Controls and exit replay before changing the live game.")}
  end

  def handle_event("continue_hand", _params, socket) do
    case GameAdapter.continue_hand(socket.assigns.room_code) do
      {:ok, :ok} -> {:noreply, put_flash(socket, :info, "Continue requested")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  @impl true
  def handle_event("clipboard_copied", _params, socket) do
    {:noreply, assign(socket, :copy_feedback, true)}
  end

  @impl true
  def handle_event("reset_clipboard_feedback", _params, socket) do
    {:noreply, assign(socket, :copy_feedback, false)}
  end

  @impl true
  def handle_event("assign_seat", %{"position" => position, "user_id" => user_id}, socket) do
    case parse_seat_position(position) do
      {:ok, position_atom} ->
        room_code = socket.assigns.room_code

        parsed_user_id =
          case user_id do
            "" -> nil
            "empty" -> nil
            nil -> nil
            id -> id
          end

        Logger.info(
          "Dev assign_seat: room=#{room_code}, position=#{position_atom}, user_id=#{inspect(parsed_user_id)}"
        )

        # If a bot occupies this position, stop it before reassigning
        bots = BotManager.list_bots(room_code)

        if Map.has_key?(bots, position_atom) do
          Logger.info("Stopping bot at #{position_atom} before seat reassignment")
          BotManager.stop_bot(room_code, position_atom)
        end

        case RoomManager.dev_set_position(room_code, position_atom, parsed_user_id) do
          {:ok, updated_room} ->
            Logger.info(
              "Dev assign_seat SUCCESS: status=#{updated_room.status}, player_count=#{PidroServer.Games.Room.Positions.count(updated_room)}"
            )

            {:noreply,
             socket
             |> assign(:room, updated_room)
             |> put_flash(:info, "Seat #{position_atom} updated successfully")}

          {:error, reason} ->
            Logger.error("Dev assign_seat FAILED: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Failed to update seat: #{inspect(reason)}")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid position: #{position}")}
    end
  end

  @impl true
  def handle_event("select_position", %{"position" => position}, socket) do
    position_atom =
      case position do
        "north" -> :north
        "south" -> :south
        "east" -> :east
        "west" -> :west
        "all" -> :all
        _ -> :all
      end

    # DEV-901: Fetch legal actions when position changes
    legal_actions = get_legal_actions(socket.assigns.room_code, position_atom)

    {:noreply,
     socket
     |> assign(:selected_position, position_atom)
     |> assign(:legal_actions, legal_actions)}
  end

  @impl true
  def handle_event("toggle_view_mode", _params, socket) do
    # DEV-502: Toggle between single and split view
    new_mode =
      case socket.assigns.view_mode do
        :single -> :split
        :split -> :single
      end

    {:noreply, assign(socket, :view_mode, new_mode)}
  end

  @impl true
  def handle_event("update_bot_config", params, socket) do
    # DEV-1106: Update bot configuration in assigns
    position = String.to_existing_atom(params["position"])
    bot_configs = socket.assigns.bot_configs

    updated_config =
      Map.update!(bot_configs, position, fn config ->
        config
        |> maybe_update_type(params)
        |> maybe_update_difficulty(params)
        |> maybe_update_delay(params)
      end)

    {:noreply, assign(socket, :bot_configs, updated_config)}
  end

  @impl true
  def handle_event("apply_bot_config", _params, socket) do
    # DEV-1106: Apply bot configuration changes
    room_code = socket.assigns.room_code
    bot_configs = socket.assigns.bot_configs

    # Process each position
    Enum.each([:north, :south, :east, :west], fn position ->
      config = Map.get(bot_configs, position)
      apply_position_config(room_code, position, config)
    end)

    {:noreply, put_flash(socket, :info, "Bot configuration applied successfully")}
  end

  @impl true
  def handle_event("toggle_bot_pause", %{"position" => position}, socket) do
    # DEV-1106: Pause or resume a specific bot
    position_atom = String.to_existing_atom(position)
    room_code = socket.assigns.room_code
    bot_configs = socket.assigns.bot_configs

    config = Map.get(bot_configs, position_atom)

    result =
      if config.paused do
        BotManager.resume_bot(room_code, position_atom)
      else
        BotManager.pause_bot(room_code, position_atom)
      end

    socket =
      case result do
        :ok ->
          # Update the paused state
          updated_configs =
            Map.update!(bot_configs, position_atom, fn c ->
              %{c | paused: !c.paused}
            end)

          socket
          |> assign(:bot_configs, updated_configs)
          |> assign(:bots_paused, all_bots_paused?(updated_configs))
          |> put_flash(
            :info,
            "Bot #{position} #{if config.paused, do: "resumed", else: "paused"}"
          )

        {:error, :not_found} ->
          put_flash(socket, :error, "Bot not found for position #{position}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_all_bots_pause", _params, socket) do
    room_code = socket.assigns.room_code
    bot_configs = socket.assigns.bot_configs
    pausing = !socket.assigns.bots_paused

    updated_configs =
      Enum.reduce([:north, :east, :south, :west], bot_configs, fn position, acc ->
        config = Map.get(acc, position)

        if config.type == :bot do
          if pausing do
            BotManager.pause_bot(room_code, position)
          else
            BotManager.resume_bot(room_code, position)
          end

          Map.update!(acc, position, fn c -> %{c | paused: pausing} end)
        else
          acc
        end
      end)

    {:noreply,
     socket
     |> assign(:bot_configs, updated_configs)
     |> assign(:bots_paused, pausing)
     |> put_flash(:info, if(pausing, do: "All bots paused", else: "All bots resumed"))}
  end

  @impl true
  def handle_event("execute_action", %{"action" => action_json}, socket) do
    # DEV-903: Execute action implementation
    socket = assign(socket, :executing_action, true)
    room_code = socket.assigns.room_code

    case decode_action(action_json) do
      {:ok, {:select_hand, :choose_6_cards}} ->
        # Intercept placeholder action and perform auto-selection
        # This handles cases where user clicks the button instead of using the card table
        game_state = socket.assigns.game_state
        dealer = game_state.current_dealer

        if game_state.current_turn == dealer do
          dealer_player = Map.get(game_state.players, dealer)
          pool = dealer_player.hand ++ game_state.deck
          trump_suit = game_state.trump_suit

          # Use DealerRob logic to select best cards
          selected_cards = Pidro.Game.DealerRob.select_best_cards(pool, trump_suit)

          # Construct actual action with selected cards
          action = {:select_hand, selected_cards}

          case GameAdapter.apply_action(room_code, dealer, action) do
            {:ok, _new_state} ->
              # Refetch game state and legal actions
              game_state = get_game_state(room_code)
              legal_actions = get_legal_actions(room_code, socket.assigns.selected_position)

              {:noreply,
               socket
               |> assign(:game_state, game_state)
               |> assign(:legal_actions, legal_actions)
               |> assign(:executing_action, false)
               |> put_flash(:info, "Auto-selected best hand for dealer")}

            {:error, reason} ->
              error_message = format_error(reason)
              Logger.error("Auto-select hand failed: #{error_message}")

              {:noreply,
               socket
               |> assign(:executing_action, false)
               |> put_flash(:error, "Auto-selection failed: #{error_message}")}
          end
        else
          {:noreply,
           socket
           |> assign(:executing_action, false)
           |> put_flash(:error, "Not dealer's turn to select hand")}
        end

      {:ok, action} ->
        # Special handling for select_dealer in God Mode
        position =
          if action == :select_dealer && socket.assigns.selected_position == :all do
            :north
          else
            socket.assigns.selected_position
          end

        # Apply the action
        case GameAdapter.apply_action(room_code, position, action) do
          {:ok, _new_state} ->
            # Refetch game state and legal actions
            game_state = get_game_state(room_code)
            legal_actions = get_legal_actions(room_code, position)

            {:noreply,
             socket
             |> assign(:game_state, game_state)
             |> assign(:legal_actions, legal_actions)
             |> assign(:executing_action, false)
             |> put_flash(:info, "Action executed successfully: #{format_action(action)}")}

          {:error, reason} ->
            # DEV-904: Error handling
            error_message = format_error(reason)
            Logger.error("Action execution failed: #{error_message}")

            {:noreply,
             socket
             |> assign(:executing_action, false)
             |> put_flash(:error, "Action failed: #{error_message}")}
        end

      {:error, error_message} ->
        # DEV-904: Exception handling
        Logger.error("Exception executing action: #{error_message}")

        {:noreply,
         socket
         |> assign(:executing_action, false)
         |> put_flash(:error, "Action failed: #{error_message}")}
    end
  end

  @impl true
  def handle_event("play_card", %{"card" => card_string}, socket) do
    # DEV-1505: Handle card click from card table
    position = socket.assigns.selected_position
    room_code = socket.assigns.room_code
    game_state = socket.assigns.game_state

    # Don't allow actions in god mode
    if position == :all do
      {:noreply, put_flash(socket, :error, "Select a specific position to play cards")}
    else
      # Decode card from string format "rank:suit"
      card = PidroServerWeb.CardHelpers.decode_card(card_string)

      # Check if we are in second_deal phase and dealer needs to rob
      # Check if we are allowed to execute actions for this position
      is_hand_selection =
        game_state.phase == :second_deal and
          game_state.current_dealer == position and
          Enum.any?(socket.assigns.legal_actions, fn
            {:select_hand, _} -> true
            _ -> false
          end)

      if is_hand_selection do
        # Toggle card selection
        selected = socket.assigns.selected_hand_cards

        new_selected =
          if card in selected do
            List.delete(selected, card)
          else
            if length(selected) < 6 do
              [card | selected]
            else
              selected
            end
          end

        {:noreply, assign(socket, :selected_hand_cards, new_selected)}
      else
        # Normal play card action
        action = {:play_card, card}
        socket = assign(socket, :executing_action, true)

        case GameAdapter.apply_action(room_code, position, action) do
          {:ok, _new_state} ->
            game_state = get_game_state(room_code)
            legal_actions = get_legal_actions(room_code, position)

            {:noreply,
             socket
             |> assign(:game_state, game_state)
             |> assign(:legal_actions, legal_actions)
             |> assign(:executing_action, false)
             |> put_flash(:info, "Played #{PidroServerWeb.CardHelpers.format_card(card)}")}

          {:error, reason} ->
            error_message = format_error(reason)
            Logger.error("Card play failed: #{error_message}")

            {:noreply,
             socket
             |> assign(:executing_action, false)
             |> put_flash(:error, "Cannot play card: #{error_message}")}
        end
      end
    end
  end

  @impl true
  def handle_event("submit_hand_selection", _params, socket) do
    selected_cards = socket.assigns.selected_hand_cards
    position = socket.assigns.selected_position
    room_code = socket.assigns.room_code

    if length(selected_cards) != 6 do
      {:noreply, put_flash(socket, :error, "You must select exactly 6 cards")}
    else
      # Construct the action for dealer robbing the pack
      action = {:select_hand, selected_cards}
      socket = assign(socket, :executing_action, true)

      case GameAdapter.apply_action(room_code, position, action) do
        {:ok, _new_state} ->
          game_state = get_game_state(room_code)
          legal_actions = get_legal_actions(room_code, position)

          {:noreply,
           socket
           |> assign(:game_state, game_state)
           |> assign(:legal_actions, legal_actions)
           |> assign(:executing_action, false)
           |> assign(:selected_hand_cards, [])
           |> put_flash(:info, "Hand selected successfully")}

        {:error, reason} ->
          error_message = format_error(reason)
          Logger.error("Hand selection failed: #{error_message}")

          {:noreply,
           socket
           |> assign(:executing_action, false)
           |> put_flash(:error, "Failed to select hand: #{error_message}")}
      end
    end
  end

  @impl true
  def handle_event("refresh_events", _params, socket) do
    # Re-process events from game state
    events = process_events(game_events(socket), socket.assigns)

    {:noreply, assign(socket, :events, events)}
  end

  @impl true
  def handle_event("filter_events", %{"type" => type}, socket) do
    type_atom = if type == "all", do: nil, else: String.to_existing_atom(type)

    new_assigns = assign(socket.assigns, :event_filter_type, type_atom)
    events = process_events(game_events(socket), new_assigns)

    {:noreply,
     socket
     |> assign(:event_filter_type, type_atom)
     |> assign(:events, events)}
  end

  @impl true
  def handle_event("filter_events_by_player", %{"player" => player}, socket) do
    player_atom = if player == "all", do: nil, else: String.to_existing_atom(player)

    new_assigns = assign(socket.assigns, :event_filter_player, player_atom)
    events = process_events(game_events(socket), new_assigns)

    {:noreply,
     socket
     |> assign(:event_filter_player, player_atom)
     |> assign(:events, events)}
  end

  @impl true
  def handle_event("clear_events", _params, socket) do
    # Cannot clear immutable event history, just clear local view or notify user
    {:noreply, put_flash(socket, :info, "Event history is immutable in GameState")}
  end

  @impl true
  def handle_event("toggle_bot_reasoning", _params, socket) do
    # Toggle bot reasoning visibility and refresh events
    new_value = !socket.assigns.show_bot_reasoning

    new_assigns = assign(socket.assigns, :show_bot_reasoning, new_value)
    events = process_events(game_events(socket), new_assigns)

    {:noreply,
     socket
     |> assign(:show_bot_reasoning, new_value)
     |> assign(:events, events)}
  end

  @impl true
  def handle_event("toggle_export_modal", _params, socket) do
    {:noreply, assign(socket, :show_event_export, !socket.assigns.show_event_export)}
  end

  @impl true
  def handle_event("export_events_json", _params, socket) do
    # This will be handled by a LiveView hook for downloading
    {:noreply, socket}
  end

  @impl true
  def handle_event("undo_last_action", _params, socket) do
    # DEV-1001: Undo last action
    room_code = socket.assigns.room_code

    case GameAdapter.undo(room_code) do
      {:ok, previous_state} ->
        # Refetch legal actions
        legal_actions = get_legal_actions(room_code, socket.assigns.selected_position)
        socket = reconcile_reasons(socket, previous_state.events)

        {:noreply,
         socket
         |> assign(:game_state, previous_state)
         |> assign(:legal_actions, legal_actions)
         |> assign(:events, process_events(previous_state.events, socket.assigns))
         |> put_flash(:info, "Action undone successfully")}

      {:error, :no_history} ->
        {:noreply, put_flash(socket, :error, "No actions to undo")}

      {:error, reason} ->
        error_message = format_error(reason)

        {:noreply, put_flash(socket, :error, "Undo failed: #{error_message}")}
    end
  end

  @impl true
  def handle_event("play_again", _params, socket) do
    room_code = socket.assigns.room_code

    # 1. Stop the current game process
    case PidroServer.Games.GameSupervisor.stop_game(room_code) do
      result when result in [:ok, {:error, :game_not_found}] ->
        # 2. Start a new game process
        case PidroServer.Games.GameSupervisor.start_game(room_code) do
          {:ok, _pid} ->
            # 3. Ensure RoomManager knows we are playing again
            PidroServer.Games.RoomManager.update_room_status(room_code, :playing)

            # 4. Refresh state
            game_state = get_game_state(room_code)
            legal_actions = get_legal_actions(room_code, socket.assigns.selected_position)
            events = process_events(game_state.events)

            {:noreply,
             socket
             |> assign(:game_state, game_state)
             |> assign(:legal_actions, legal_actions)
             |> assign(:bot_reasons, [])
             |> assign(:events, events)
             |> put_flash(:info, "Game restarted! Good luck.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to restart game: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop previous game: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("auto_bid", _params, socket) do
    # DEV-1002: Auto-complete bidding phase
    room_code = socket.assigns.room_code

    # Start auto-bidding in a separate process to avoid blocking
    parent = self()

    Task.start(fn ->
      case GameHelpers.auto_bid(room_code, delay_ms: 500) do
        {:ok, _final_state} ->
          send(parent, {:auto_bid_complete, :success})

        {:error, :not_in_bidding_phase} ->
          send(parent, {:auto_bid_complete, {:error, "Game is not in bidding phase"}})

        {:error, reason} ->
          send(parent, {:auto_bid_complete, {:error, inspect(reason)}})
      end
    end)

    {:noreply, put_flash(socket, :info, "Auto-bidding started...")}
  end

  @impl true
  def handle_event("fast_forward", _params, socket) do
    # DEV-1003: Fast-forward game to completion
    room_code = socket.assigns.room_code

    case GameHelpers.fast_forward(room_code, delay_ms: 100) do
      {:ok, :started} ->
        {:noreply,
         put_flash(socket, :info, "Fast-forward started - bots will play automatically")}

      {:error, reason} ->
        error_message = format_error(reason)

        {:noreply, put_flash(socket, :error, "Fast-forward failed: #{error_message}")}
    end
  end

  # DEV-1301: Replay Controls Event Handlers

  @impl true
  def handle_event("toggle_replay_mode", _params, socket) do
    new_mode = !socket.assigns.replay_mode

    socket =
      if new_mode do
        # Every replay operation reads this immutable source, even across rematches.
        source = socket.assigns.game_state || %{events: []}

        socket
        |> assign(:replay_mode, true)
        |> assign(:replay_source, source)
        |> assign(:replay_total_events, length(source.events))
        |> assign(:replay_index, length(source.events) - 1)
        |> put_flash(:info, "Replay mode activated")
      else
        # Exiting replay mode - restore live state
        game_state = get_game_state(socket.assigns.room_code)
        events = if game_state, do: game_state.events, else: []
        {:ok, room} = RoomManager.get_room(socket.assigns.room_code)
        bot_configs = initialize_bot_configs(socket.assigns.room_code)

        # Live reasoning received during replay was deliberately discarded.
        socket = assign(socket, :bot_reasons, [])

        legal_actions =
          get_legal_actions(socket.assigns.room_code, socket.assigns.selected_position)

        socket
        |> assign(:replay_mode, false)
        |> assign(:replay_source, nil)
        |> assign(:replay_playing, false)
        |> assign(:room, room)
        |> assign(:bot_configs, bot_configs)
        |> assign(:bots_paused, all_bots_paused?(bot_configs))
        |> refresh_seats()
        |> assign(:game_state, game_state)
        |> assign(:replay_total_events, length(events))
        |> assign(:replay_index, length(events) - 1)
        |> assign(:events, process_events(events, socket.assigns))
        |> assign(:legal_actions, legal_actions)
        |> put_flash(:info, "Replay mode deactivated")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_step_backward", _params, socket) do
    if socket.assigns.replay_mode do
      case ReplayController.step_backward(
             socket.assigns.replay_source,
             socket.assigns.replay_index
           ) do
        {:ok, state, new_index} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, new_index)
           |> assign(:legal_actions, [])}

        {:error, :at_start} ->
          {:noreply, put_flash(socket, :info, "Already at the start")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Step backward failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_step_forward", _params, socket) do
    if socket.assigns.replay_mode do
      case ReplayController.step_forward(
             socket.assigns.replay_source,
             socket.assigns.replay_index
           ) do
        {:ok, state, new_index} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, new_index)
           |> assign(:legal_actions, [])}

        {:error, :at_end} ->
          {:noreply, put_flash(socket, :info, "Already at the end")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Step forward failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_jump_to", %{"index" => index_str}, socket) do
    if socket.assigns.replay_mode do
      index = String.to_integer(index_str)

      case ReplayController.get_state_at_event(socket.assigns.replay_source, index) do
        {:ok, state} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, index)
           |> assign(:legal_actions, [])}

        {:error, :invalid_index} ->
          {:noreply, put_flash(socket, :error, "Invalid event index")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Jump failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_jump_to_phase", %{"phase" => phase}, socket) do
    if socket.assigns.replay_mode do
      phase_atom = String.to_existing_atom(phase)

      case ReplayController.jump_to_phase(socket.assigns.replay_source, phase_atom) do
        {:ok, state, index} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, index)
           |> assign(:legal_actions, [])
           |> put_flash(:info, "Jumped to #{format_phase(phase_atom)} phase")}

        {:error, :phase_not_found} ->
          {:noreply, put_flash(socket, :error, "Phase not reached yet")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Jump to phase failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_toggle_play", _params, socket) do
    if socket.assigns.replay_mode do
      new_playing = !socket.assigns.replay_playing

      socket =
        if new_playing do
          # Start auto-play
          send(self(), :replay_tick)
          assign(socket, :replay_playing, true)
        else
          # Stop auto-play
          assign(socket, :replay_playing, false)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_set_speed", %{"speed" => speed_str}, socket) do
    speed = String.to_integer(speed_str)
    {:noreply, assign(socket, :replay_speed, speed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="games"
      title={"Table #{@room_code}"}
      subtitle="Private admin observation. All hands are visible only here; watching never takes a seat."
      flash={@flash}
    >
      <:actions>
        <.link
          navigate={~p"/admin/games"}
          class="inline-flex items-center gap-2 rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm font-bold text-stone-700 shadow-sm hover:border-orange-300 hover:text-stone-950"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Tables
        </.link>
        <a
          href={"/admin/history?" <> URI.encode_query(%{"room_code" => @room_code})}
          class="rounded border border-stone-300 bg-white px-3 py-2 text-sm font-bold"
        >
          Room history
        </a>
        <button
          :if={@active_tab == :controls and not @replay_mode}
          type="button"
          phx-click="toggle_all_bots_pause"
          class={[
            "inline-flex items-center gap-2 rounded-sm px-3 py-2 text-sm font-bold shadow-sm transition active:translate-y-px",
            if(@bots_paused,
              do: "border border-emerald-300 bg-emerald-50 text-emerald-800 hover:bg-emerald-100",
              else: "border border-amber-300 bg-amber-50 text-amber-800 hover:bg-amber-100"
            )
          ]}
        >
          <%= if @bots_paused do %>
            <.icon name="hero-play" class="size-4" /> Resume Bots
          <% else %>
            <.icon name="hero-pause" class="size-4" /> Pause Bots
          <% end %>
        </button>
      </:actions>

      <.render_tab_bar active_tab={@active_tab} room_code={@room_code} />

      <div id="watch-status" class="flex flex-wrap items-center gap-3 text-sm text-stone-700">
        <strong>{if @replay_mode, do: "REPLAY · historical game state", else: "LIVE · #{@room.status}"}</strong>
        <dl class="flex gap-1">
          <dt>Seated:</dt><dd>{PidroServer.Games.Room.Positions.count(@room)} / 4</dd>
        </dl>
        <span :if={@bots_paused}>Bots paused (not a game pause)</span>
        <span :if={@game_state}>Pace: {Map.get(@game_state.config, :pace, :quick)}</span>
        <strong :if={@game_state && @game_state.phase == :hand_complete}>Awaiting continue</strong>
      </div>

      <.render_watch_tab :if={@active_tab == :board} {assigns} />
      <.render_roster :if={@active_tab == :seats_bots} seats={@seats} />
      <%= if @active_tab == :controls do %>
        <div class="rounded border border-amber-400 bg-amber-50 p-4 text-amber-950">
          <strong>Intervention controls change the live game for everyone.</strong>
          Return to Table to leave this mode. Replay must be exited before intervening.
          <button
            :if={@game_state && @game_state.phase == :hand_complete}
            phx-click="continue_hand"
            class="ml-3 rounded border px-3 py-2"
          >Continue hand</button>
        </div>
        <.render_seats_tab {assigns} />
      <% end %>
      <.render_room_info :if={@active_tab == :inspect} room={@room} />
      <.render_board_tab :if={@active_tab != :seats_bots} {assigns} />
    </.admin_shell>
    """
  end

  defp render_room_info(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
      <div class="px-4 py-3">
        <h3 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
          Room Information
        </h3>
      </div>
      <div class="border-t border-stone-200 px-4 py-4">
        <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-3">
          <div>
            <dt class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Status
            </dt>
            <dd class="mt-1 text-sm text-zinc-900">
              <span class={"px-2 inline-flex text-xs leading-5 font-semibold rounded-full #{status_color(@room.status)}"}>
                {@room.status}
              </span>
            </dd>
          </div>
          <div>
            <dt class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Players
            </dt>
            <dd class="mt-1 text-sm text-zinc-900">
              {PidroServer.Games.Room.Positions.count(@room)} / 4
            </dd>
          </div>
          <div>
            <dt class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Host
            </dt>
            <dd class="mt-1 text-sm text-zinc-900">
              <%= if @room.host_id do %>
                {String.slice(@room.host_id, 0..7)}...
              <% else %>
                No owner
              <% end %>
            </dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  defp render_tab_bar(assigns) do
    ~H"""
    <div class="rounded-md border border-stone-300 bg-white px-3 py-2 shadow-sm">
      <nav class="flex flex-wrap gap-2" aria-label="Tabs">
        <.link
          :for={
            {tab, label} <- [
              board: "Table",
              activity: "Activity",
              seats_bots: "Seats & bots",
              inspect: "Inspect",
              controls: "Controls"
            ]
          }
          patch={~p"/admin/games/#{@room_code}?tab=#{tab}"}
          aria-current={if @active_tab == tab, do: "page"}
          class={[
            "whitespace-nowrap rounded-sm px-3 py-2 text-sm font-bold",
            if(@active_tab == tab,
              do: "bg-stone-950 text-white",
              else: "text-stone-600 hover:bg-stone-100 hover:text-stone-950"
            )
          ]}
        >
          {label}
        </.link>
      </nav>
    </div>
    """
  end

  defp render_watch_tab(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-sm">
      <span class="font-semibold">Private hand visibility:</span>
      <button
        :for={position <- [:all, :north, :east, :south, :west]}
        phx-click="select_position"
        phx-value-position={position}
        aria-pressed={@selected_position == position}
        class={[
          "rounded border px-3 py-2",
          if(@selected_position == position, do: "bg-stone-900 text-white", else: "bg-white")
        ]}
      >
        {if position == :all, do: "All hands (admin)", else: format_position(position)}
      </button>
    </div>
    <CardComponents.watch_table
      game_state={@game_state}
      seats={@seats}
      perspective={@selected_position}
    />
    <p :if={@replay_mode} class="text-sm text-amber-800">
      Replay freezes the captured game, seats and reasoning. The live game continues independently.
    </p>
    """
  end

  defp render_roster(assigns) do
    ~H"""
    <div class="watch-roster">
      <CardComponents.seat_identity
        :for={position <- [:north, :east, :south, :west]}
        seat={@seats[position]}
        position={position}
      />
    </div>
    <p class="text-sm text-stone-600">
      Observation only. Seat reassignment and bot configuration are in Controls. IDs are in Inspect.
    </p>
    """
  end

  defp render_board_tab(assigns) do
    ~H"""
    <%= if @active_tab == :controls do %>
      <!-- Position Selector - DEV-401 & DEV-502 -->
      <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
        <div class="px-4 py-5 sm:px-6 flex justify-between items-start">
          <div>
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Position Filter & View Mode</h3>
            <p class="mt-1 text-sm text-zinc-500">Select a position to view and execute actions</p>
          </div>
          <%!-- DEV-502: Split View Toggle --%>
          <button
            type="button"
            phx-click="toggle_view_mode"
            class={[
              "px-4 py-2 text-sm font-medium rounded-md transition-all shadow-sm",
              if(@view_mode == :split,
                do: "bg-purple-600 text-white ring-2 ring-purple-300",
                else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
              )
            ]}
            title="Toggle split screen view (4 quadrants)"
          >
            <%= if @view_mode == :split do %>
              <svg class="w-5 h-5 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1V5zM14 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1V5zM4 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1v-4zM14 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1v-4z"
                />
              </svg>
              Split View Active
            <% else %>
              <svg class="w-5 h-5 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 5a1 1 0 011-1h14a1 1 0 011 1v14a1 1 0 01-1 1H5a1 1 0 01-1-1V5z"
                />
              </svg>
              Enable Split View
            <% end %>
          </button>
        </div>
        <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
          <div class="mb-4 flex justify-between items-center">
            <div class={[
              "inline-flex items-center px-3 py-1 rounded-md text-sm font-medium",
              if(@selected_position == :all,
                do: "bg-purple-100 text-purple-800",
                else: "bg-blue-100 text-blue-800"
              )
            ]}>
              <%= if @selected_position == :all do %>
                God Mode (All Players)
              <% else %>
                Playing as: {format_position(@selected_position)}
              <% end %>
            </div>
            <%= if @view_mode == :split do %>
              <div class="text-xs text-purple-600 font-medium">
                Split view: {format_position(@selected_position)} highlighted
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Take a Seat Shortcut -->
      <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
        <div class="px-4 py-5 sm:px-6">
          <h3 class="text-lg leading-6 font-medium text-zinc-900">Take a Seat</h3>
          <p class="mt-1 text-sm text-zinc-500">
            Quick seat assignment without leaving the Board tab
          </p>
        </div>
        <div class="border-t border-zinc-200 px-4 py-4 sm:px-6">
          <form phx-submit="assign_seat" class="flex items-end gap-3">
            <div class="flex-shrink-0">
              <label class="block text-xs font-medium text-zinc-700 mb-1">Position</label>
              <select name="position" class="text-sm rounded border-zinc-300 py-1.5">
                <%= for pos <- [:north, :east, :south, :west] do %>
                  <option value={to_string(pos)}>
                    {format_position(pos)}
                    <%= if @room.positions[pos] do %>
                      (occupied)
                    <% else %>
                      (empty)
                    <% end %>
                  </option>
                <% end %>
              </select>
            </div>
            <div class="flex-1">
              <label class="block text-xs font-medium text-zinc-700 mb-1">User</label>
              <select name="user_id" class="w-full text-sm rounded border-zinc-300 py-1.5">
                <option value="empty">-- Clear seat --</option>
                <%= for user <- @users do %>
                  <option value={user.id}>
                    {user_label(user)}
                  </option>
                <% end %>
              </select>
            </div>
            <button
              type="submit"
              class="px-4 py-1.5 text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 transition-colors"
            >
              Assign
            </button>
          </form>
        </div>
      </div>

      <!-- Dev Quick Actions - DEV-1001 to DEV-1003 Implementation -->
      <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
        <div class="px-4 py-5 sm:px-6">
          <h3 class="text-lg leading-6 font-medium text-zinc-900">Dev Quick Actions</h3>
          <p class="mt-1 text-sm text-zinc-500">
            Testing shortcuts for rapid development iteration
          </p>
        </div>
        <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
          <div class="flex flex-wrap gap-3">
            <button
              type="button"
              phx-click="undo_last_action"
              class="inline-flex items-center px-4 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 transition-colors"
              title="Undo the last game action"
            >
              <svg
                class="w-5 h-5 mr-2"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"
                />
              </svg>
              Undo Last Action
            </button>

            <button
              type="button"
              phx-click="auto_bid"
              class="inline-flex items-center px-4 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 transition-colors"
              title="Automatically complete the bidding phase"
            >
              <svg
                class="w-5 h-5 mr-2"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
              Auto-complete Bidding
            </button>

            <button
              type="button"
              phx-click="fast_forward"
              class="inline-flex items-center px-4 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 transition-colors"
              title="Fast forward the game to completion"
            >
              <svg
                class="w-5 h-5 mr-2"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M5 3l14 9-14 9V3z"
                />
              </svg>
              Fast Forward
            </button>
          </div>
        </div>
      </div>
    <% end %>
    <!-- DEV-1301: Hand Replay Controls -->
    <%= if @replay_total_events > 0 and @active_tab in [:board, :controls] do %>
      <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
        <div class="px-4 py-5 sm:px-6 flex justify-between items-center">
          <div>
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Hand Replay</h3>
            <p class="mt-1 text-sm text-zinc-500">
              Step through game history event by event
            </p>
          </div>
          <button
            type="button"
            phx-click="toggle_replay_mode"
            class={[
              "px-4 py-2 text-sm font-medium rounded-md transition-all shadow-sm",
              if(@replay_mode,
                do: "bg-amber-600 text-white ring-2 ring-amber-300",
                else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
              )
            ]}
          >
            <%= if @replay_mode do %>
              <svg
                class="w-5 h-5 inline mr-1"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
              Exit Replay
            <% else %>
              <svg
                class="w-5 h-5 inline mr-1"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12.066 11.2a1 1 0 000 1.6l5.334 4A1 1 0 0019 16V8a1 1 0 00-1.6-.8l-5.333 4zM4.066 11.2a1 1 0 000 1.6l5.334 4A1 1 0 0011 16V8a1 1 0 00-1.6-.8l-5.334 4z"
                />
              </svg>
              Enter Replay Mode
            <% end %>
          </button>
        </div>
        <%= if @replay_mode do %>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6 bg-amber-50">
            <!-- Event Progress Bar -->
            <div class="mb-4">
              <div class="flex justify-between text-sm text-zinc-700 mb-2">
                <span>Event {@replay_index + 1} of {@replay_total_events}</span>
                <%= if @replay_index >= 0 && @replay_index < @replay_total_events do %>
                  <%= case ReplayController.get_event_info(@replay_source, @replay_index) do %>
                    <% {:ok, event_info} -> %>
                      <span class="text-zinc-600 italic">{event_info.description}</span>
                    <% _ -> %>
                      <span></span>
                  <% end %>
                <% end %>
              </div>
              <input
                type="range"
                min="0"
                max={@replay_total_events - 1}
                value={@replay_index}
                phx-change="replay_jump_to"
                name="index"
                class="w-full h-2 bg-zinc-200 rounded-lg appearance-none cursor-pointer accent-amber-600"
              />
            </div>
            <!-- Playback Controls -->
            <div class="flex items-center justify-between gap-3">
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  phx-click="replay_step_backward"
                  class="px-3 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 disabled:opacity-50"
                  disabled={@replay_index <= 0}
                >
                  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M15 19l-7-7 7-7"
                    />
                  </svg>
                </button>
                <button
                  type="button"
                  phx-click="replay_toggle_play"
                  class={[
                    "px-4 py-2 shadow-sm text-sm font-medium rounded-md text-white transition-colors",
                    if(@replay_playing,
                      do: "bg-red-600 hover:bg-red-700",
                      else: "bg-green-600 hover:bg-green-700"
                    )
                  ]}
                >
                  <%= if @replay_playing do %>
                    <svg class="w-5 h-5 inline" fill="currentColor" viewBox="0 0 24 24">
                      <path d="M6 4h4v16H6V4zm8 0h4v16h-4V4z" />
                    </svg>
                    Pause
                  <% else %>
                    <svg class="w-5 h-5 inline" fill="currentColor" viewBox="0 0 24 24">
                      <path d="M8 5v14l11-7z" />
                    </svg>
                    Play
                  <% end %>
                </button>
                <button
                  type="button"
                  phx-click="replay_step_forward"
                  class="px-3 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 disabled:opacity-50"
                  disabled={@replay_index >= @replay_total_events - 1}
                >
                  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 5l7 7-7 7"
                    />
                  </svg>
                </button>
              </div>
              <div class="flex items-center gap-3">
                <label class="text-sm text-zinc-700">Speed:</label>
                <select
                  name="speed"
                  phx-change="replay_set_speed"
                  class="px-2 py-1 text-sm border border-zinc-300 rounded-md bg-white"
                >
                  <option value="2000" selected={@replay_speed == 2000}>0.5x</option>
                  <option value="1000" selected={@replay_speed == 1000}>1x</option>
                  <option value="500" selected={@replay_speed == 500}>2x</option>
                  <option value="250" selected={@replay_speed == 250}>4x</option>
                </select>
              </div>
              <!-- Jump to Phase -->
              <div class="flex items-center gap-2">
                <label class="text-sm text-zinc-700">Jump to:</label>
                <select
                  phx-change="replay_jump_to_phase"
                  name="phase"
                  class="px-2 py-1 text-sm border border-zinc-300 rounded-md bg-white"
                >
                  <option value="">Select phase...</option>
                  <option value="dealer_selection">Dealer Selection</option>
                  <option value="dealing">Dealing</option>
                  <option value="bidding">Bidding</option>
                  <option value="declaring">Trump Declaration</option>
                  <option value="discarding">Discarding</option>
                  <option value="second_deal">Second Deal</option>
                  <option value="playing">Playing</option>
                  <option value="scoring">Scoring</option>
                </select>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>

    <%= if @active_tab == :controls do %>
      <!-- Card Table UI - DEV-1505 & DEV-502: Visual Card Table Integration with Split View -->
      <%= if @game_state && @view_mode == :split && @game_state.phase == :playing do %>
        <%!-- DEV-502: Split View Layout (2x2 Grid) --%>
        <div class="mb-8">
          <div class="bg-gradient-to-br from-purple-50 to-purple-100 p-4 rounded-lg shadow-lg">
            <div class="text-center mb-3">
              <h3 class="text-lg font-semibold text-purple-900">Split View Mode</h3>
              <p class="text-sm text-purple-700">
                Viewing all 4 player perspectives simultaneously
              </p>
            </div>
            <div class="grid grid-cols-2 gap-4">
              <%= for position <- [:north, :south, :east, :west] do %>
                <.render_position_view
                  position={position}
                  game_state={@game_state}
                  selected_position={@selected_position}
                  room_code={@room_code}
                />
              <% end %>
            </div>
          </div>
        </div>
      <% else %>
        <%!-- Single View Layout (or Waiting State) --%>
        <div class="mb-8 relative">
          <CardComponents.card_table
            game_state={@game_state}
            selected_position={@selected_position}
            god_mode={@selected_position == :all}
            legal_actions={@legal_actions}
            bot_configs={@bot_configs}
            room={@room}
            users={@users}
            show_seat_selectors={true}
          />

          <%= if @game_state && @game_state.phase == :complete do %>
            <div class="absolute inset-0 bg-gray-900/60 backdrop-blur-sm flex items-center justify-center z-10 rounded-xl">
              <div class="bg-white rounded-xl shadow-2xl max-w-lg w-full overflow-hidden transform transition-all scale-100 ring-1 ring-black/5 m-4">
                <div class="p-6 text-center border-b bg-gradient-to-r from-indigo-50 to-purple-50">
                  <h2 class="text-3xl font-extrabold text-gray-900 mb-2">Game Over!</h2>
                  <p class="text-lg text-indigo-600 font-medium">
                    <%= case @game_state.winner do %>
                      <% :north_south -> %>
                        North/South Wins!
                      <% :east_west -> %>
                        East/West Wins!
                      <% _ -> %>
                        Game Complete
                    <% end %>
                  </p>
                </div>

                <div class="p-6">
                  <div class="grid grid-cols-2 gap-8 mb-8 text-center">
                    <div class="p-4 bg-blue-50 rounded-lg border-2 border-blue-100">
                      <div class="text-sm text-blue-600 font-bold uppercase tracking-wider mb-1">
                        North/South
                      </div>
                      <div class="text-4xl font-black text-blue-800">
                        {@game_state.cumulative_scores.north_south}
                      </div>
                    </div>
                    <div class="p-4 bg-green-50 rounded-lg border-2 border-green-100">
                      <div class="text-sm text-green-600 font-bold uppercase tracking-wider mb-1">
                        East/West
                      </div>
                      <div class="text-4xl font-black text-green-800">
                        {@game_state.cumulative_scores.east_west}
                      </div>
                    </div>
                  </div>

                  <h3 class="text-sm font-bold text-gray-500 uppercase tracking-wider mb-3">
                    Score History
                  </h3>
                  <div class="bg-gray-50 rounded-lg border overflow-hidden max-h-48 overflow-y-auto mb-6">
                    <table class="min-w-full divide-y divide-gray-200">
                      <thead class="bg-gray-100">
                        <tr>
                          <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                            Hand
                          </th>
                          <th class="px-4 py-2 text-center text-xs font-medium text-blue-600 uppercase">
                            N/S
                          </th>
                          <th class="px-4 py-2 text-center text-xs font-medium text-green-600 uppercase">
                            E/W
                          </th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-gray-200 bg-white">
                        <%= for {score, index} <- get_score_history(@game_state.events) do %>
                          <tr>
                            <td class="px-4 py-2 text-sm text-gray-900">#{index}</td>
                            <td class="px-4 py-2 text-sm text-center font-medium text-blue-700">
                              {if score.ns > 0, do: "+#{score.ns}", else: score.ns}
                            </td>
                            <td class="px-4 py-2 text-sm text-center font-medium text-green-700">
                              {if score.ew > 0, do: "+#{score.ew}", else: score.ew}
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>

                  <div class="flex gap-3">
                    <.link
                      navigate={~p"/admin/games"}
                      class="flex-1 bg-gray-100 hover:bg-gray-200 text-gray-800 font-bold py-3 px-4 rounded-lg text-center transition-colors"
                    >
                      Back to Lobby
                    </.link>
                    <button
                      phx-click="play_again"
                      class="flex-1 bg-indigo-600 hover:bg-indigo-700 text-white font-bold py-3 px-4 rounded-lg text-center transition-colors shadow-md"
                    >
                      Play Again
                    </button>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- Action Execution - DEV-901 to DEV-904 Implementation -->
      <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
        <div class="px-4 py-5 sm:px-6">
          <h3 class="text-lg leading-6 font-medium text-zinc-900">Legal Actions</h3>
          <p class="mt-1 text-sm text-zinc-500">
            <%= if @selected_position == :all do %>
              Select a specific position to view and execute actions
            <% else %>
              Execute game actions for position:
              <span class="font-semibold">{@selected_position}</span>
            <% end %>
          </p>
        </div>
        <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
          <%= if @selected_position == :all do %>
            <div class="text-sm text-zinc-500 italic">
              Please select a specific position above to view legal actions.
            </div>
          <% else %>
            <%= if @executing_action do %>
              <div class="flex items-center justify-center py-8">
                <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600"></div>
                <span class="ml-3 text-sm text-zinc-600">Executing action...</span>
              </div>
            <% else %>
              <%= if Enum.empty?(@legal_actions) do %>
                <div class="text-sm text-zinc-500 italic">
                  No legal actions available for this position at this time.
                </div>
              <% else %>
                <%!-- DEV-902: Render action buttons grouped by type --%>
                <.render_action_groups legal_actions={@legal_actions} />
              <% end %>
            <% end %>
          <% end %>
        </div>
      </div>
    <% end %>
    <!-- Game State Card -->
    <%= if @game_state do %>
      <div :if={@active_tab == :inspect} class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
        <div class="px-4 py-5 sm:px-6">
          <h3 class="text-lg leading-6 font-medium text-zinc-900">Game State</h3>
          <p class="mt-1 max-w-2xl text-sm text-zinc-500">
            Current phase: <span class="font-semibold">{@game_state.phase}</span>
          </p>
        </div>
        <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
          <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
            <div>
              <dt class="text-sm font-medium text-zinc-500">Current Turn</dt>
              <dd class="mt-1 text-sm text-zinc-900">
                {inspect(@game_state.current_turn)}
              </dd>
            </div>
            <%= if Map.has_key?(@game_state, :dealer) do %>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Dealer</dt>
                <dd class="mt-1 text-sm text-zinc-900">{inspect(@game_state.dealer)}</dd>
              </div>
            <% end %>
            <%= if Map.has_key?(@game_state, :trump_suit) && @game_state.trump_suit do %>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Trump Suit</dt>
                <dd class="mt-1 text-sm text-zinc-900">
                  {format_suit(@game_state.trump_suit)}
                </dd>
              </div>
            <% end %>
            <%= if Map.has_key?(@game_state, :winning_bid) && @game_state.winning_bid do %>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Winning Bid</dt>
                <dd class="mt-1 text-sm text-zinc-900">
                  {@game_state.winning_bid.amount} by {@game_state.winning_bid.team}
                </dd>
              </div>
            <% end %>
          </dl>

          <!-- Scores -->
          <%= if Map.has_key?(@game_state, :scores) do %>
            <div class="mt-6">
              <h4 class="text-sm font-medium text-zinc-500 mb-3">Scores</h4>
              <div class="grid grid-cols-2 gap-4">
                <div class="bg-blue-50 p-4 rounded-lg">
                  <div class="text-sm font-medium text-blue-900">North-South</div>
                  <div class="text-2xl font-bold text-blue-700">
                    {@game_state.scores.north_south}
                  </div>
                </div>
                <div class="bg-green-50 p-4 rounded-lg">
                  <div class="text-sm font-medium text-green-900">East-West</div>
                  <div class="text-2xl font-bold text-green-700">
                    {@game_state.scores.east_west}
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Event Log Panel (FR-7 / DEV-704) --%>
      <div :if={@active_tab == :activity} class="bg-white rounded-lg shadow-md p-4 sm:p-6 mb-8">
        <div :if={@connection_events != []} class="mb-4 border-b pb-4 text-sm">
          <h3 class="font-semibold">Connection transitions · newest first · since opening</h3>
          <p :for={entry <- @connection_events}>{entry}</p>
        </div>
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-xl font-semibold">Event Log</h2>
          <div class="flex gap-2">
            <button
              phx-click="refresh_events"
              class="px-3 py-1 text-sm bg-blue-500 text-white rounded hover:bg-blue-600"
            >
              Refresh
            </button>
            <button
              phx-click="clear_events"
              data-confirm="Are you sure you want to clear the event log?"
              class="px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600"
            >
              Clear
            </button>
            <button
              phx-click="toggle_export_modal"
              class="px-3 py-1 text-sm bg-green-500 text-white rounded hover:bg-green-600"
            >
              Export
            </button>
          </div>
        </div>

        <%!-- Filters --%>
        <div class="flex flex-wrap gap-4 mb-4 items-end">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Filter by Type</label>
            <select
              phx-change="filter_events"
              name="type"
              class="rounded border-gray-300"
            >
              <option value="all" selected={is_nil(@event_filter_type)}>All Events</option>
              <option value="bid_made" selected={@event_filter_type == :bid_made}>Bids</option>
              <option value="bid_passed" selected={@event_filter_type == :bid_passed}>
                Passes
              </option>
              <option value="trump_declared" selected={@event_filter_type == :trump_declared}>
                Trump Declared
              </option>
              <option value="card_played" selected={@event_filter_type == :card_played}>
                Cards Played
              </option>
              <option value="trick_won" selected={@event_filter_type == :trick_won}>
                Tricks Won
              </option>
              <option value="hand_scored" selected={@event_filter_type == :hand_scored}>
                Hand Scored
              </option>
            </select>
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Filter by Player</label>
            <select
              phx-change="filter_events_by_player"
              name="player"
              class="rounded border-gray-300"
            >
              <option value="all" selected={is_nil(@event_filter_player)}>All Players</option>
              <option value="north" selected={@event_filter_player == :north}>North</option>
              <option value="south" selected={@event_filter_player == :south}>South</option>
              <option value="east" selected={@event_filter_player == :east}>East</option>
              <option value="west" selected={@event_filter_player == :west}>West</option>
            </select>
          </div>

          <div class="flex items-center">
            <label class="inline-flex items-center cursor-pointer">
              <input
                type="checkbox"
                phx-click="toggle_bot_reasoning"
                checked={@show_bot_reasoning}
                class="rounded border-gray-300 text-indigo-600 shadow-sm focus:border-indigo-300 focus:ring focus:ring-indigo-200 focus:ring-opacity-50"
              />
              <span class="ml-2 text-sm text-gray-700">Show Bot Reasoning</span>
            </label>
          </div>
        </div>

        <%!-- Event List --%>
        <div id="watch-activity" class="bg-gray-50 rounded p-4 max-h-[600px] overflow-y-auto text-sm">
          <%= if Enum.empty?(@events) do %>
            <p class="text-gray-500 italic">No events recorded yet</p>
          <% else %>
            <div class="space-y-1">
              <%= for event <- Enum.reverse(@events) do %>
                <div class="border-b border-stone-200 py-2">
                  <strong :if={event.player}>{CardComponents.seat_name(@seats[event.player])} · </strong>
                  <span class="text-gray-500">[#{event.metadata[:index] || "?"}]</span>
                  <span class={event_type_color(event.type)}>
                    {Event.format(event)}
                  </span>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="mt-2 text-sm text-gray-600">
          Newest first · Showing {length(@events)} entries (last 50; reasoning available since opening)
        </div>
      </div>

      <%!-- Export Modal (FR-7 / DEV-705) --%>
      <%= if @show_event_export and @active_tab == :activity do %>
        <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div class="bg-white rounded-lg shadow-xl p-6 max-w-2xl w-full mx-4">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold">Export Events</h3>
              <button
                phx-click="toggle_export_modal"
                class="text-gray-500 hover:text-gray-700"
              >
                x
              </button>
            </div>

            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">JSON Format</label>
                <textarea
                  id="export-json"
                  readonly
                  class="w-full h-64 font-mono text-xs border rounded p-2"
                >{Jason.encode!(@events |> Enum.map(&Event.to_json/1), pretty: true)}</textarea>
                <button
                  id="copy-json-button"
                  phx-hook="Clipboard"
                  data-target="export-json"
                  class="mt-2 px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
                >
                  Copy JSON
                </button>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Text Format</label>
                <textarea
                  id="export-text"
                  readonly
                  class="w-full h-64 font-mono text-xs border rounded p-2"
                >{Enum.map_join(@events, "\n", fn event ->
                  "[##{event.metadata[:index] || "?"}] #{Event.format(event)}"
                end)}</textarea>
                <button
                  id="copy-text-button"
                  phx-hook="Clipboard"
                  data-target="export-text"
                  class="mt-2 px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
                >
                  Copy Text
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Full State JSON (collapsible) -->
      <details :if={@active_tab == :inspect} class="bg-white shadow overflow-hidden sm:rounded-lg">
        <summary class="px-4 py-5 sm:px-6 cursor-pointer hover:bg-zinc-50">
          <div class="flex items-center justify-between">
            <div>
              <h3 class="text-lg leading-6 font-medium text-zinc-900 inline">
                Full Game State (Raw)
              </h3>
            </div>
            <button
              id="copy-game-state"
              type="button"
              phx-hook="Clipboard"
              data-clipboard-text={
                inspect(%{game: @game_state, seats: @seats}, pretty: true, limit: :infinity)
              }
              class="px-3 py-1 text-sm font-medium rounded-md bg-indigo-600 text-white hover:bg-indigo-700 transition-colors"
              onclick="event.stopPropagation()"
            >
              <%= if @copy_feedback do %>
                <span>Copied!</span>
              <% else %>
                <span>Copy State</span>
              <% end %>
            </button>
          </div>
        </summary>
        <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
          <pre class="text-xs bg-zinc-50 p-4 rounded overflow-auto"><%= inspect(%{game: @game_state, seats: @seats}, pretty: true, limit: :infinity) %></pre>
        </div>
      </details>
    <% else %>
      <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-6">
        <p class="text-yellow-800">
          Game has not started yet or state is unavailable.
        </p>
      </div>
    <% end %>
    """
  end

  defp render_seats_tab(assigns) do
    ~H"""
    <!-- Bot Configuration - DEV-1106 -->
    <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
      <div class="px-4 py-5 sm:px-6">
        <h3 class="text-lg leading-6 font-medium text-zinc-900">Bot Configuration</h3>
        <p class="mt-1 text-sm text-zinc-500">Configure bot players for each seat</p>
      </div>
      <div class="border-t border-zinc-200 px-4 py-4">
        <div class="grid grid-cols-2 gap-3 mb-3">
          <%= for position <- [:north, :south, :east, :west] do %>
            <.render_bot_position_config position={position} config={@bot_configs[position]} />
          <% end %>
        </div>
        <button
          type="button"
          phx-click="apply_bot_config"
          class="w-full px-3 py-2 text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700"
        >
          Apply Changes
        </button>
      </div>
    </div>

    <!-- Seat Management -->
    <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
      <div class="px-4 py-5 sm:px-6">
        <h3 class="text-lg leading-6 font-medium text-zinc-900">Seat Management</h3>
        <p class="mt-1 text-sm text-zinc-500">Assign users to seats or manage bot positions</p>
      </div>
      <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
        <div class="grid grid-cols-2 gap-4">
          <%= for position <- [:north, :east, :south, :west] do %>
            <div class="bg-zinc-50 rounded-lg p-4">
              <div class="flex items-center justify-between mb-2">
                <h4 class="text-sm font-semibold text-zinc-900">{format_position(position)}</h4>
                <span class={[
                  "px-2 py-0.5 text-xs rounded-full font-medium",
                  if(@room.positions[position],
                    do: "bg-green-100 text-green-800",
                    else: "bg-zinc-200 text-zinc-600"
                  )
                ]}>
                  {if @room.positions[position], do: "Occupied", else: "Empty"}
                </span>
              </div>
              <%= if @room.positions[position] do %>
                <p class="text-xs text-zinc-600 mb-2 font-mono truncate">
                  {@room.positions[position] |> String.slice(0..11)}...
                </p>
              <% end %>
              <form phx-submit="assign_seat" class="flex gap-2">
                <input type="hidden" name="position" value={to_string(position)} />
                <select
                  name="user_id"
                  class="flex-1 text-xs rounded border-zinc-300 py-1"
                >
                  <option value="empty">-- Clear --</option>
                  <%= for user <- @users do %>
                    <option value={user.id}>
                      {user_label(user)}
                    </option>
                  <% end %>
                </select>
                <button
                  type="submit"
                  class="px-3 py-1 text-xs font-medium rounded bg-indigo-600 text-white hover:bg-indigo-700"
                >
                  Set
                </button>
              </form>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # DEV-502: Render individual position view quadrant for split view
  defp render_position_view(assigns) do
    position = assigns.position
    is_active = assigns.selected_position == position
    legal_actions = if is_active, do: get_legal_actions(assigns.room_code, position), else: []

    assigns =
      assigns
      |> assign(:is_active, is_active)
      |> assign(:position_legal_actions, legal_actions)

    ~H"""
    <div class={[
      "bg-white rounded-lg shadow-md border-2 transition-all",
      if(@is_active, do: "border-indigo-500 ring-2 ring-indigo-300", else: "border-gray-200")
    ]}>
      <%!-- Position Header --%>
      <div class={[
        "px-3 py-2 rounded-t-lg border-b flex justify-between items-center",
        if(@is_active, do: "bg-indigo-50 border-indigo-200", else: "bg-gray-50 border-gray-200")
      ]}>
        <div class="flex items-center gap-2">
          <span class={[
            "font-semibold text-sm",
            if(@is_active, do: "text-indigo-900", else: "text-gray-700")
          ]}>
            {format_position(@position)}
          </span>
          <%= if @is_active do %>
            <span class="text-xs bg-indigo-600 text-white px-2 py-0.5 rounded">Active</span>
          <% end %>
          <%= if @game_state.current_turn == @position do %>
            <span class="text-xs bg-green-500 text-white px-2 py-0.5 rounded animate-pulse">
              Turn
            </span>
          <% end %>
        </div>
        <%!-- Card count --%>
        <span class="text-xs text-gray-600">
          {length(get_selected_hand(@game_state, @position))} cards
        </span>
      </div>
      <%!-- Position Content --%>
      <div class="p-3">
        <%!-- Hand Display (Compact) --%>
        <div class="mb-2">
          <div class="text-xs font-medium text-gray-500 mb-1">Hand:</div>
          <div class="flex flex-wrap gap-1">
            <%= for card <- get_selected_hand(@game_state, @position) |> Enum.take(12) do %>
              <div class="inline-block">
                <CardComponents.card card={card} size={:sm} face_down={false} />
              </div>
            <% end %>
            <%= if length(get_selected_hand(@game_state, @position)) > 12 do %>
              <span class="text-xs text-gray-500 self-center">
                +{length(get_selected_hand(@game_state, @position)) - 12} more
              </span>
            <% end %>
          </div>
        </div>
        <%!-- Legal Actions Count --%>
        <%= if @is_active && @position_legal_actions != [] do %>
          <div class="mt-2 text-xs">
            <span class="text-green-600 font-medium">
              {length(@position_legal_actions)} legal actions
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp user_label(user) do
    Map.get(user, :username) || String.slice(user.id, 0..11)
  end

  # DEV-1106: Render bot position configuration
  defp render_bot_position_config(assigns) do
    ~H"""
    <div class="bg-zinc-50 rounded p-2 text-xs">
      <div class="font-semibold text-zinc-900 mb-1">{format_position(@position)}</div>
      <div class="flex gap-1 mb-1">
        <button
          type="button"
          phx-click="update_bot_config"
          phx-value-position={@position}
          phx-value-type="human"
          class={[
            "flex-1 px-2 py-1 rounded",
            if(@config.type == :human, do: "bg-indigo-600 text-white", else: "bg-white text-zinc-700")
          ]}
        >
          Human
        </button>
        <button
          type="button"
          phx-click="update_bot_config"
          phx-value-position={@position}
          phx-value-type="bot"
          class={[
            "flex-1 px-2 py-1 rounded",
            if(@config.type == :bot, do: "bg-indigo-600 text-white", else: "bg-white text-zinc-700")
          ]}
        >
          Bot
        </button>
      </div>
      <%= if @config.type == :bot do %>
        <select
          phx-change="update_bot_config"
          phx-value-position={@position}
          name="difficulty"
          class="w-full rounded border-zinc-300 text-xs"
        >
          <option value="random" selected={@config.difficulty == :random}>Random</option>
          <option value="basic" selected={@config.difficulty == :basic}>Basic</option>
          <option value="smart" selected={@config.difficulty == :smart}>Smart</option>
        </select>
      <% end %>
    </div>
    """
  end

  # DEV-902: Render action buttons grouped by type
  defp render_action_groups(assigns) do
    grouped = group_actions(assigns.legal_actions)
    assigns = assign(assigns, :grouped_actions, grouped)

    ~H"""
    <div class="space-y-6">
      <%= for {group_name, group_actions} <- @grouped_actions do %>
        <div>
          <h4 class="text-sm font-medium text-zinc-700 mb-2">{group_name}</h4>
          <div class="flex flex-wrap gap-2">
            <%= for action <- group_actions do %>
              <button
                type="button"
                phx-click="execute_action"
                phx-value-action={encode_action(action)}
                class="px-3 py-2 text-sm font-medium rounded-md bg-indigo-600 text-white hover:bg-indigo-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {format_action_text(action)}
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Private functions

  defp get_game_state(room_code) do
    case GameAdapter.get_state(room_code) do
      {:ok, state} -> state
      {:error, _} -> nil
    end
  end

  # DEV-901: Fetch legal actions for a position
  defp get_legal_actions(_room_code, :all), do: []

  defp get_legal_actions(room_code, position) when is_atom(position) do
    case GameAdapter.get_legal_actions(room_code, position) do
      {:ok, actions} -> actions
      {:error, _} -> []
    end
  end

  # DEV-902: Format action text for display
  defp format_action_text(action) do
    case action do
      :pass -> "Pass"
      {:bid, amount} -> "Bid #{amount}"
      {:play_card, {rank, suit}} -> "Play #{format_card(rank, suit)}"
      {:declare_trump, suit} -> "Declare #{format_suit(suit)}"
      {:select_hand, :choose_6_cards} -> "Choose 6 Cards"
      _ -> inspect(action)
    end
  end

  defp format_card(rank, suit) do
    "#{format_rank(rank)}#{format_suit_symbol(suit)}"
  end

  defp format_rank(rank) do
    case rank do
      14 -> "A"
      13 -> "K"
      12 -> "Q"
      11 -> "J"
      n -> to_string(n)
    end
  end

  defp format_suit_symbol(suit) do
    case suit do
      :hearts -> "♥"
      :diamonds -> "♦"
      :clubs -> "♣"
      :spades -> "♠"
      _ -> to_string(suit)
    end
  end

  defp format_action(action) do
    case action do
      :pass -> "Pass"
      {:bid, amount} -> "Bid #{amount}"
      {:play_card, {rank, suit}} -> "Play #{format_card(rank, suit)}"
      {:declare_trump, suit} -> "Declare #{format_suit(suit)}"
      _ -> inspect(action)
    end
  end

  # DEV-902: Group actions by type
  defp group_actions(actions) do
    actions
    |> Enum.group_by(&action_type/1)
    |> Enum.map(fn {type, acts} -> {type_label(type), acts} end)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp action_type(action) do
    case action do
      :pass -> :bidding
      {:bid, _} -> :bidding
      {:declare_trump, _} -> :trump
      {:play_card, _} -> :cards
      {:select_hand, _} -> :hand_selection
      _ -> :other
    end
  end

  defp type_label(type) do
    case type do
      :bidding -> "Bidding Actions"
      :trump -> "Trump Declaration"
      :cards -> "Card Play"
      :hand_selection -> "Hand Selection"
      :other -> "Other Actions"
    end
  end

  # Encode/decode actions for phx-click
  defp encode_action(:pass), do: Jason.encode!("pass")
  defp encode_action(:select_dealer), do: Jason.encode!("select_dealer")
  defp encode_action({:bid, amount}), do: Jason.encode!(["bid", amount])
  defp encode_action({:declare_trump, suit}), do: Jason.encode!(["declare_trump", suit])
  defp encode_action({:play_card, {rank, suit}}), do: Jason.encode!(["play_card", [rank, suit]])
  defp encode_action({:select_hand, sub_action}), do: Jason.encode!(["select_hand", sub_action])
  defp encode_action(action), do: Jason.encode!(action)

  defp decode_action(action_json) do
    case Jason.decode(action_json) do
      {:ok, "pass"} ->
        {:ok, :pass}

      {:ok, "select_dealer"} ->
        {:ok, :select_dealer}

      {:ok, ["bid", amount]} ->
        {:ok, {:bid, amount}}

      {:ok, ["declare_trump", suit]} ->
        {:ok, {:declare_trump, String.to_existing_atom(suit)}}

      {:ok, ["play_card", [rank, suit]]} ->
        {:ok, {:play_card, {rank, String.to_existing_atom(suit)}}}

      {:ok, ["select_hand", sub_action]} ->
        {:ok, {:select_hand, String.to_existing_atom(sub_action)}}

      {:error, error} ->
        {:error, "Invalid action format: #{inspect(error)}"}

      _ ->
        {:error, "Invalid action format: #{action_json}"}
    end
  rescue
    ArgumentError -> {:error, "Invalid action format: unknown atom in #{action_json}"}
    error -> {:error, "Invalid action format: #{Exception.message(error)}"}
  end

  # DEV-904: Format error messages
  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_error(reason), do: inspect(reason)

  defp parse_seat_position(position) do
    case position do
      "north" -> {:ok, :north}
      "south" -> {:ok, :south}
      "east" -> {:ok, :east}
      "west" -> {:ok, :west}
      _ -> :error
    end
  end

  defp status_color(status) do
    case status do
      :waiting -> "bg-yellow-100 text-yellow-800"
      :ready -> "bg-blue-100 text-blue-800"
      :playing -> "bg-green-100 text-green-800"
      :finished -> "bg-gray-100 text-gray-800"
      :closed -> "bg-red-100 text-red-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end

  defp format_suit(suit) do
    case suit do
      :hearts -> "♥ Hearts"
      :diamonds -> "♦ Diamonds"
      :clubs -> "♣ Clubs"
      :spades -> "♠ Spades"
      _ -> inspect(suit)
    end
  end

  defp format_position(position) do
    case position do
      :north -> "North"
      :south -> "South"
      :east -> "East"
      :west -> "West"
      :all -> "All Players"
      _ -> inspect(position)
    end
  end

  # DEV-1106: Bot configuration helper functions

  defp initialize_bot_configs(room_code, fallback \\ nil) do
    # Fetch current bots from BotManager
    current_bots = BotManager.list_bots(room_code)

    # Initialize config for each position
    [:north, :south, :east, :west]
    |> Enum.map(fn position ->
      config =
        case Map.get(current_bots, position) do
          nil ->
            # No bot exists - default to human
            @human_bot_config

          bot_info ->
            # Bot exists - populate config
            %{
              type: :bot,
              difficulty: bot_info.strategy,
              delay_ms: 1000,
              paused: bot_info.status == :paused
            }
        end

      {position, config}
    end)
    |> Map.new()
  catch
    :exit, _ ->
      fallback || Map.new([:north, :south, :east, :west], &{&1, @human_bot_config})
  end

  defp all_bots_paused?(bot_configs) do
    bots = Enum.filter(bot_configs, fn {_pos, config} -> config.type == :bot end)
    bots != [] and Enum.all?(bots, fn {_pos, config} -> config.paused end)
  end

  defp maybe_update_type(config, %{"type" => type}) when type in ["human", "bot"] do
    %{config | type: String.to_existing_atom(type)}
  end

  defp maybe_update_type(config, _params), do: config

  defp maybe_update_difficulty(config, %{"difficulty" => difficulty})
       when difficulty in ["random", "basic", "smart"] do
    %{config | difficulty: String.to_existing_atom(difficulty)}
  end

  defp maybe_update_difficulty(config, _params), do: config

  defp maybe_update_delay(config, %{"delay_ms" => delay_str}) do
    case Integer.parse(delay_str) do
      {delay, _} when delay >= 0 and delay <= 3000 ->
        %{config | delay_ms: delay}

      _ ->
        config
    end
  end

  defp maybe_update_delay(config, _params), do: config

  defp apply_position_config(room_code, position, config) do
    current_bots = BotManager.list_bots(room_code)
    bot_exists = Map.has_key?(current_bots, position)

    # Default :unknown strategy to :random
    difficulty = if config.difficulty == :unknown, do: :random, else: config.difficulty

    case {config.type, bot_exists} do
      {:bot, false} ->
        # Start a new bot
        # Check if seat is empty before starting bot
        room = RoomManager.get_room(room_code) |> elem(1)
        is_seat_empty = is_seat_available?(room, position)

        if is_seat_empty do
          BotManager.start_bot(room_code, position, difficulty, config.delay_ms)
        else
          # Seat is occupied by a human (potentially the admin/host)
          # We can't just overwrite a human player with a bot unless we kick them first
          # For now, let's just log it or maybe force start if it's dev mode
          Logger.info("Cannot start bot at #{position}, seat occupied by human")
          {:error, :seat_occupied}
        end

      {:bot, true} ->
        # Bot exists - stop and restart with new config
        BotManager.stop_bot(room_code, position)
        # Small delay to ensure cleanup
        Process.sleep(100)
        BotManager.start_bot(room_code, position, difficulty, config.delay_ms)

      {:human, true} ->
        # Stop the bot
        BotManager.stop_bot(room_code, position)

      {:human, false} ->
        # No bot exists, and user wants human - nothing to do
        :ok
    end
  end

  defp is_seat_available?(room, position) do
    # Helper to check if a seat is physically occupied by a player ID
    alias PidroServer.Games.Room.Positions

    # Check if the position is occupied in the positions map
    not Positions.has_player?(room, room.positions[position])
  end

  # Event log helper functions

  defp event_type_color(type) do
    case type do
      :bid_made -> "text-blue-600"
      :bid_passed -> "text-gray-500"
      :trump_declared -> "text-purple-600"
      :card_played -> "text-green-600"
      :trick_won -> "text-yellow-600"
      :hand_scored -> "text-orange-600"
      :game_over -> "text-red-600"
      :bot_reasoning -> "text-indigo-600 italic"
      _ -> "text-gray-700"
    end
  end

  # DEV-1505 & DEV-1506: Helper functions for card table and phase displays

  defp get_selected_hand(_state, :all), do: []

  defp get_selected_hand(state, position) when is_atom(position) do
    with %{players: players} <- state,
         %{hand: hand} <- Map.get(players, position) do
      hand
    else
      _ -> []
    end
  end

  # Helper function to process and filter events from game state
  defp process_events(raw_events, assigns \\ %{}) do
    filter_type = Map.get(assigns, :event_filter_type, nil)
    filter_player = Map.get(assigns, :event_filter_player, nil)
    show_bot = Map.get(assigns, :show_bot_reasoning, true)

    engine_events =
      raw_events
      |> Enum.with_index(1)
      |> Enum.map(fn {raw, idx} -> Event.from_raw(raw, idx) end)
      |> Enum.reject(&is_nil/1)

    reasons = assigns |> Map.get(:bot_reasons, []) |> Enum.map(&Event.from_bot_reasoning/1)

    # A reason sorts just before the first event its move produced.
    (engine_events ++ reasons)
    |> Enum.sort_by(&{&1.metadata[:index], if(&1.type == :bot_reasoning, do: 0, else: 1)})
    |> filter_by_type(filter_type)
    |> filter_by_player(filter_player)
    |> filter_bot_reasoning(show_bot)
    |> Enum.take(-50)
  end

  defp filter_by_type(events, nil), do: events
  defp filter_by_type(events, type), do: Enum.filter(events, &(&1.type == type))

  defp filter_by_player(events, nil), do: events
  defp filter_by_player(events, player), do: Enum.filter(events, &(&1.player == player))

  defp filter_bot_reasoning(events, true), do: events
  defp filter_bot_reasoning(events, false), do: Enum.reject(events, &(&1.type == :bot_reasoning))

  # Helper function to extract score history
  defp get_score_history(events) do
    events
    |> Enum.filter(fn
      {:hand_scored, _, _} -> true
      _ -> false
    end)
    # Group NS and EW scores for same hand
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [{:hand_scored, :east_west, ew}, {:hand_scored, :north_south, ns}] ->
        %{ns: ns, ew: ew}

      [{:hand_scored, :north_south, ns}, {:hand_scored, :east_west, ew}] ->
        %{ns: ns, ew: ew}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(1)
  end

  # DEV-1301: Format phase names for display
  defp format_phase(phase) do
    case phase do
      :dealer_selection -> "Dealer Selection"
      :dealing -> "Dealing"
      :bidding -> "Bidding"
      :declaring -> "Trump Declaration"
      :discarding -> "Discarding"
      :second_deal -> "Second Deal"
      :playing -> "Playing"
      :scoring -> "Scoring"
      :complete -> "Complete"
      _ -> phase |> to_string() |> String.capitalize()
    end
  end
end
