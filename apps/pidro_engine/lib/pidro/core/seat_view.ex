defmodule Pidro.Core.SeatView do
  @moduledoc """
  What one seat is allowed to know about a game.

  A seat view is the only input a bot strategy may decide from. It is its own
  data shape, not a `GameState`: the viewer's hand, a public record for every
  seat, and the public table fields. Hidden information is absent rather than
  blanked, so another seat's hand is a count (`players[pos].hand_count`), never
  an empty list that could be mistaken for "holds nothing". `GameState` stays
  reserved for authoritative transitions; a view cannot be fed to the engine.

  The view is built from an allow-list of public fields, so a field added to
  `GameState` later stays hidden until it is added here on purpose. Trick and
  scoring helpers such as `Pidro.Game.Play.determine_trick_winner/2` and
  `Pidro.Finnish.Scorer` take tricks and trump suits, so they run on a view's
  fields directly.

  ## What a seat can see

  - Its own hand.
  - Bids, trump, tricks played, the current trick, and the scores.
  - How many cards each non-dealer drew in the second deal (`cards_requested`).
  - Its own folded cards, other seats' folded counts, and cards killed this hand.
  - How many cards every seat holds.
  - The dealer's rob pool, but only for the dealer during a manual rob.

  ## What stays hidden

  Other seats' hands and folded faces, the deck, the discards, the dealer's
  pool size, and the raw event log. The event log carries every dealt,
  second-dealt and discarded card and is never reset between hands, so no
  part of it is exposed.
  """

  use TypedStruct

  alias Pidro.Core.Types
  alias Pidro.Core.Types.{Bid, GameState, Trick}

  typedstruct module: PublicPlayer do
    @moduledoc """
    What every seat can see about one player.
    """
    field(:position, Pidro.Core.Types.position(), enforce: true)
    field(:team, Pidro.Core.Types.team(), enforce: true)
    field(:hand_count, non_neg_integer(), enforce: true)
    field(:eliminated?, boolean(), default: false)
    field(:revealed_cards, [Pidro.Core.Types.card()], default: [])
    field(:folded_count, non_neg_integer(), default: 0)
    field(:tricks_won, non_neg_integer(), default: 0)
  end

  typedstruct do
    field(:position, Types.position(), enforce: true)
    field(:hand, [Types.card()], enforce: true)
    field(:players, %{Types.position() => PublicPlayer.t()}, enforce: true)
    field(:phase, Types.phase(), enforce: true)
    field(:hand_number, non_neg_integer(), enforce: true)
    field(:variant, atom(), enforce: true)
    field(:config, map(), enforce: true)
    field(:current_dealer, Types.position() | nil)
    field(:current_turn, Types.position() | nil)
    field(:dealer_selection_cuts, %{Types.position() => Types.card()} | nil)
    field(:bids, [Bid.t()], default: [])
    field(:highest_bid, {Types.position(), Types.bid_amount()} | nil)
    field(:bidding_team, Types.team() | nil)
    field(:trump_suit, Types.suit() | nil)
    field(:cards_requested, %{Types.position() => non_neg_integer()}, default: %{})
    field(:killed_cards, %{Types.position() => [Types.card()]}, default: %{})
    field(:tricks, [Trick.t()], default: [])
    field(:current_trick, Trick.t() | nil)
    field(:trick_number, non_neg_integer(), default: 0)
    field(:hand_points, %{Types.team() => non_neg_integer()}, default: %{})
    field(:cumulative_scores, %{Types.team() => integer()}, default: %{})
    field(:winner, Types.team() | nil)
    field(:rob_pool, [Types.card()], default: [])
  end

  @doc """
  Builds the view of `state` from the seat at `position`.

  ## Parameters

  - `state` - The full, authoritative game state
  - `position` - The seat whose view to build

  ## Returns

  A `SeatView` holding the viewer's hand, a `PublicPlayer` per seat, the
  public table fields, the kills of the current hand (see `killed_cards/1`),
  and, for the dealer during a manual rob, the rob pool.

  ## Examples

      iex> view = Pidro.Core.SeatView.for_seat(Pidro.Core.GameState.new(seed: 7), :north)
      iex> {view.position, view.hand, view.players.east.hand_count}
      {:north, [], 0}
  """
  @spec for_seat(GameState.t(), Types.position()) :: t()
  def for_seat(%GameState{} = state, position)
      when position in [:north, :east, :south, :west] do
    %__MODULE__{
      position: position,
      hand: state.players[position].hand,
      players:
        Map.new(state.players, fn {pos, player} -> {pos, public_player(player, position)} end),
      phase: state.phase,
      hand_number: state.hand_number,
      variant: state.variant,
      config: state.config,
      current_dealer: state.current_dealer,
      current_turn: state.current_turn,
      dealer_selection_cuts: state.dealer_selection_cuts,
      bids: state.bids,
      highest_bid: state.highest_bid,
      bidding_team: state.bidding_team,
      trump_suit: state.trump_suit,
      cards_requested: state.cards_requested,
      killed_cards: killed_cards(state),
      tricks: state.tricks,
      current_trick: state.current_trick,
      trick_number: state.trick_number,
      hand_points: state.hand_points,
      cumulative_scores: state.cumulative_scores,
      winner: state.winner,
      rob_pool: rob_pool(state, position)
    }
  end

  @doc """
  Returns the cards each seat killed in the current hand.

  The engine's `killed_cards` field is recomputed after every play and is
  empty from the second card of a hand onward, so this reads the
  `:cards_killed` events instead. It takes, per seat, the first non-empty
  entry recorded since the hand's `:cards_dealt` event.

  ## Parameters

  - `state` - The full game state

  ## Returns

  A map of position to killed cards; seats that killed nothing are absent.

  ## Examples

      iex> Pidro.Core.SeatView.killed_cards(Pidro.Core.GameState.new(seed: 7))
      %{}
  """
  @spec killed_cards(GameState.t()) :: %{Types.position() => [Types.card()]}
  def killed_cards(%GameState{events: events}) do
    events
    |> current_hand_events()
    |> Enum.reduce(%{}, fn
      {:cards_killed, kills}, acc ->
        Enum.reduce(kills, acc, fn
          {_pos, []}, inner -> inner
          {pos, cards}, inner -> Map.put_new(inner, pos, cards)
        end)

      _event, acc ->
        acc
    end)
  end

  @doc """
  What each player dealt to kept and threw after the discard, and drew in the
  second deal: public at any table, where everyone sees how many cards each
  of them throws and is dealt. Never the dealer's: the dealer throws unseen
  and takes the rest of the pack, and how many trumps they kept is the
  dealer's edge. Empty before the discard and once the hand is over.

  ## Examples

      iex> Pidro.Core.SeatView.second_deal_counts(Pidro.Core.GameState.new(seed: 7))
      %{}
  """
  @spec second_deal_counts(GameState.t()) :: %{
          Types.position() => %{
            kept: non_neg_integer(),
            discarded: non_neg_integer(),
            drawn: non_neg_integer()
          }
        }
  def second_deal_counts(%GameState{phase: phase} = state)
      when phase in [:second_deal, :playing] do
    dealt =
      Enum.find_value(Enum.reverse(state.events), %{}, fn
        {:cards_dealt, hands} -> hands
        _event -> nil
      end)

    thrown =
      state.events
      |> current_hand_events()
      |> Enum.reduce(%{}, fn
        {:cards_discarded, pos, cards}, acc ->
          Map.update(acc, pos, length(cards), &(&1 + length(cards)))

        _event, acc ->
          acc
      end)

    for {pos, cards} <- dealt, pos != state.current_dealer, into: %{} do
      {pos,
       %{
         kept: length(cards) - Map.get(thrown, pos, 0),
         discarded: Map.get(thrown, pos, 0),
         drawn: Map.get(state.cards_requested, pos)
       }}
    end
  end

  def second_deal_counts(%GameState{}), do: %{}

  # Events after the last deal, oldest first. Every hand starts with one
  # `:cards_dealt` event, including hands after the first.
  defp current_hand_events(events) do
    events
    |> Enum.reverse()
    |> Enum.take_while(&(not match?({:cards_dealt, _}, &1)))
    |> Enum.reverse()
  end

  defp public_player(player, viewer) do
    %PublicPlayer{
      position: player.position,
      team: player.team,
      hand_count: length(player.hand),
      eliminated?: player.eliminated?,
      revealed_cards: if(player.position == viewer, do: player.revealed_cards, else: []),
      folded_count: if(player.eliminated?, do: length(player.revealed_cards), else: 0),
      tricks_won: player.tricks_won
    }
  end

  # Under manual rob the dealer picks six cards from their hand plus the deck,
  # so the dealer sees the deck while choosing. Nobody else ever does.
  defp rob_pool(%GameState{phase: :second_deal, current_dealer: dealer} = state, dealer) do
    if Map.get(state.config, :auto_dealer_rob, true), do: [], else: state.deck
  end

  defp rob_pool(_state, _position), do: []
end
