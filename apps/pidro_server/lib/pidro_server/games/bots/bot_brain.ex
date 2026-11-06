defmodule PidroServer.Games.Bots.BotBrain do
  @moduledoc """
  Shared move logic for BotPlayer and SubstituteBot.

  Contains the decision-making and action execution code common to both
  bot types. Each bot GenServer handles its own lifecycle (join vs takeover,
  pause/resume) and delegates move logic here.
  """

  require Logger

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.SeatView
  alias Pidro.Core.Types.GameState
  alias Pidro.Game.{DealerRob, Play}
  alias PidroServer.Games.{GameAdapter, Lifecycle}

  @doc """
  Returns true if the game state indicates it's this bot's turn.

  Checks that the phase is active (not :complete, :hand_complete or nil) and that either
  `current_turn` matches the bot's position or the phase is :dealer_selection.

  At quick pace a settled hand is the RoomManager's to sweep. At own pace
  the bot plays its last trumps at its normal delay.

  Note: Does NOT check paused state — callers that support pausing should
  check that separately before calling this function.
  """
  @spec should_make_move?(map(), atom()) :: boolean()
  def should_make_move?(game_state, position) do
    phase = Map.get(game_state, :phase)

    phase not in [:complete, :hand_complete, nil] and
      (Map.get(game_state, :current_turn) == position or
         phase == :dealer_selection) and
      (match?(%{config: %{pace: :own}}, game_state) or is_nil(Play.settled_play(game_state)))
  end

  @doc """
  Computes a bot delay using a base delay, symmetric random variance, and floor.
  """
  @spec compute_delay(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def compute_delay(base_ms, variance_ms, min_ms) do
    raw_delay =
      if variance_ms > 0 do
        base_ms + Enum.random(-variance_ms..variance_ms)
      else
        base_ms
      end

    max(raw_delay, min_ms)
  end

  @doc """
  Schedules a `:make_move` message using the current pacing config.

  `transition_delay_ms` is added on top of the computed bot delay. Optional
  schedule opts allow tests or explicit callers to override the base delay.
  """
  @spec schedule_move(non_neg_integer(), keyword()) :: reference()
  def schedule_move(transition_delay_ms \\ 0, opts \\ []) do
    delay_key = if Keyword.get(opts, :pace) == :own, do: :own_bot_delay_ms, else: :bot_delay_ms
    base_ms = Keyword.get(opts, :base_delay_ms, Lifecycle.config(delay_key))
    variance_ms = Keyword.get(opts, :variance_ms, Lifecycle.config(:bot_delay_variance_ms))
    min_ms = Keyword.get(opts, :min_delay_ms, Lifecycle.config(:bot_min_delay_ms))
    delay_ms = compute_delay(base_ms, variance_ms, min_ms) + transition_delay_ms

    Process.send_after(self(), :make_move, delay_ms)
  end

  @doc """
  Schedules a move only if one is not already pending.
  """
  @spec schedule_move_once(map(), non_neg_integer(), keyword()) :: map()
  def schedule_move_once(state, transition_delay_ms \\ 0, opts \\ []) do
    if Map.get(state, :move_scheduled?, false) do
      state
    else
      schedule_move(transition_delay_ms, opts)
      Map.put(state, :move_scheduled?, true)
    end
  end

  @doc """
  Executes a bot move: fetches legal actions, builds the bot's seat view,
  picks an action via the strategy, resolves it, and applies it.

  The strategy only ever sees the seat view (`Pidro.Core.SeatView`), never the
  full game state. The full state is used for one thing: resolving the dealer's
  `{:select_hand, :choose_6_cards}` marker, which is the engine's own choice
  from the pool the dealer legitimately sees.

  A strategy that raises or chooses an illegal action does not stop the turn:
  the move falls back to the rulebook's safest legal action and the failure
  is logged.

  `bot_label` is used for log messages (e.g., "BotPlayer" or "SubstituteBot").
  Both controllers supply RoomManager's PID-checked action function. The
  selected move is fenced to its snapshot, even if the same actor plays next.
  """
  @spec execute_move(map(), String.t()) :: :ok
  @spec execute_move(map(), String.t(), (String.t(), atom(), term(), tuple() -> term())) :: :ok
  def execute_move(state, bot_label, apply_action \\ &apply_move/4) do
    label = "#{bot_label} (#{state.room_code}/#{state.position})"

    with {:ok, %{state: %GameState{} = game_state, game_instance_id: instance}} <-
           GameAdapter.get_snapshot(state.room_code),
         [_ | _] = legal_actions <- Pidro.Game.Engine.legal_actions(game_state, state.position) do
      view = SeatView.for_seat(game_state, state.position)
      {action, reasoning} = choose(state.strategy, legal_actions, view, label)
      action = resolve_action(action, game_state, state.position)

      Logger.debug("#{label} executing: #{inspect(action)} - #{reasoning}")

      case apply_action.(
             state.room_code,
             state.position,
             action,
             {instance, length(game_state.events)}
           ) do
        {:ok, _new_state} ->
          publish_reasoning(state.room_code, %{
            position: state.position,
            action: action,
            reason: reasoning,
            event_index: length(game_state.events)
          })

        # Not saved, so not made: try again from a fresh read of the game.
        {:error, :game_unavailable} ->
          Logger.warning("#{label} move not saved, retrying (#{inspect(action)})")
          Process.send_after(self(), :make_move, 1_000)
          :ok

        {:error, reason} ->
          Logger.warning("#{label} action failed: #{inspect(reason)} (#{inspect(action)})")
      end
    else
      [] ->
        Logger.debug("#{label} has no legal actions")

      {:error, :not_found} ->
        Logger.warning("#{label} - game not found")

      other ->
        Logger.warning("#{label} error: #{inspect(other)}")
    end
  end

  defp apply_move(code, position, action, turn),
    do: GameAdapter.apply_action(code, position, action, 5_000, %{expected_turn: turn})

  @doc """
  Returns the per-room PubSub topic that carries each bot move's reason.

  It is separate from `game:<code>` so the players' channels and the bots
  never receive it; the admin game page subscribes to it. Each message is
  `{:bot_reasoning, room_code, %{position, action, reason, event_index}}`,
  where `event_index` is the engine event count when the bot decided, so a
  reason sorts just before the events its move produced.
  """
  @spec reasoning_topic(String.t()) :: String.t()
  def reasoning_topic(room_code), do: "bot_reasoning:#{room_code}"

  defp publish_reasoning(room_code, payload) do
    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      reasoning_topic(room_code),
      {:bot_reasoning, room_code, payload}
    )
  end

  # Strategies predating the {:ok, action, reasoning} contract return a bare
  # action; both shapes are accepted.
  defp choose(strategy, legal_actions, view, label) do
    case strategy.pick_action(legal_actions, view) do
      {:ok, action, reasoning} -> ensure_legal(action, reasoning, legal_actions, view, label)
      action -> ensure_legal(action, "legacy strategy", legal_actions, view, label)
    end
  rescue
    error ->
      Logger.error(
        "#{label} strategy #{inspect(strategy)} raised, using the rulebook fallback: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      Rulebook.fallback(view, legal_actions)
  end

  defp ensure_legal(action, reasoning, legal_actions, view, label) do
    if action in legal_actions do
      {action, reasoning}
    else
      Logger.warning(
        "#{label} strategy chose #{inspect(action)}, which is not legal; using the rulebook fallback"
      )

      Rulebook.fallback(view, legal_actions)
    end
  end

  @doc """
  Resolves placeholder actions into concrete actions.

  `{:select_hand, :choose_6_cards}` is a marker -- bots must compute actual
  card selection using `DealerRob.select_best_cards/2`.
  """
  @spec resolve_action(term(), map(), atom()) :: term()
  def resolve_action({:select_hand, :choose_6_cards}, game_state, position) do
    player = Map.get(game_state.players, position, %{})
    hand = Map.get(player, :hand, [])
    deck = Map.get(game_state, :deck, [])
    trump = Map.get(game_state, :trump_suit)
    pool = hand ++ deck
    selected = DealerRob.select_best_cards(pool, trump)
    {:select_hand, selected}
  end

  def resolve_action(action, _game_state, _position), do: action
end
