defmodule Pidro.Bot.Search.Rollout do
  @moduledoc """
  Plays one sampled world to the end of the hand with the rulebook in every
  seat, through the engine, and scores it from one seat's side.

  The state is built from the seat view and a `Pidro.Bot.Search.Determinizer`
  world: the view's public fields, the seat's own hand, and the sampled hands
  of the others. Its pace is `:own`, so the engine stops at `:hand_complete`
  and never shuffles a next hand; its chance stream is a fixed dummy and no
  game's stream is read. Every move goes through `Engine.legal_actions/2` and
  `Engine.apply_action/3`, and scoring is the engine's `Pidro.Finnish.Scorer`,
  so no rule of the game is copied here.
  """

  alias Pidro.Bot.Rulebook
  alias Pidro.Bot.Search.Determinizer
  alias Pidro.Core.{GameState, SeatView, Types}
  alias Pidro.Game.{DealerRob, Engine}

  @doc """
  Builds the game state of `world` as seen from the seat in `view`.
  """
  @spec state(SeatView.t(), Determinizer.world()) :: Types.GameState.t()
  def state(%SeatView{} = view, world) do
    base = GameState.new(seed: 0, variant: view.variant)

    players =
      Map.new(base.players, fn {pos, player} ->
        public = view.players[pos]
        own? = pos == view.position

        {pos,
         %{
           player
           | hand: if(own?, do: view.hand, else: world.hands[pos]),
             eliminated?: public.eliminated?,
             revealed_cards:
               if(own?, do: public.revealed_cards, else: Map.get(world.folded, pos, [])),
             tricks_won: public.tricks_won
         }}
      end)

    %{
      base
      | phase: view.phase,
        hand_number: view.hand_number,
        config: Map.put(view.config, :pace, :own),
        players: players,
        current_dealer: view.current_dealer,
        current_turn: view.current_turn,
        deck: world.deck,
        discarded_cards: world.discards,
        bids: view.bids,
        highest_bid: view.highest_bid,
        bidding_team: view.bidding_team,
        trump_suit: view.trump_suit,
        cards_requested: view.cards_requested,
        tricks: view.tricks,
        current_trick: view.current_trick,
        trick_number: view.trick_number,
        hand_points: view.hand_points,
        cumulative_scores: view.cumulative_scores,
        events: [{:cards_dealt, %{}}, {:cards_killed, view.killed_cards}]
    }
  end

  @doc """
  Applies `action` for `position`, then plays the hand out with the rulebook
  in every seat. Returns the state at `:hand_complete`, or `:complete` when
  the hand ended the game.
  """
  @spec run(Types.GameState.t(), Types.position(), Types.action()) :: Types.GameState.t()
  def run(state, position, action) do
    {:ok, next} = Engine.apply_action(state, position, resolve(action, state, position))
    play_out(next)
  end

  @doc """
  The hand's worth to the side of `position`: its score change minus the
  other side's, as the engine scored it (a set contract counts its bid),
  plus or minus the winning score when the hand ended the game.
  """
  @spec value(Types.GameState.t(), Types.position()) :: integer()
  def value(%{last_hand: %{delta: delta}} = final, position) do
    team = Types.position_to_team(position)
    hand = delta[team] - delta[Types.opposing_team(team)]

    case final do
      %{phase: :complete, winner: ^team} -> hand + final.config.winning_score
      %{phase: :complete} -> hand - final.config.winning_score
      _ -> hand
    end
  end

  defp play_out(%{phase: phase} = state) when phase in [:hand_complete, :complete], do: state

  defp play_out(%{current_turn: position} = state) do
    legal = Engine.legal_actions(state, position)
    {action, _reason} = Rulebook.decide(SeatView.for_seat(state, position), legal)
    run(state, position, action)
  end

  # The dealer's rob stays with the engine's own selection, as in self-play.
  defp resolve({:select_hand, :choose_6_cards}, state, position) do
    pool = state.players[position].hand ++ state.deck
    {:select_hand, DealerRob.select_best_cards(pool, state.trump_suit)}
  end

  defp resolve(action, _state, _position), do: action
end
