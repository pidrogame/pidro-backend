defmodule PidroServerWeb.Serializers.GameStateSerializer do
  @moduledoc """
  Serializes Pidro game state structs into JSON-safe maps.

  Used by both REST API controllers and WebSocket channels to ensure
  consistent game state representation across all interfaces.
  """

  alias Pidro.Core.SeatView
  alias Pidro.Core.Types.GameState

  @doc """
  Serializes game state with all player hands hidden (card counts only).

  Used by REST endpoints where exposing hands would enable cheating.
  Each player's hand is replaced with a card_count field.
  """
  @spec serialize_public(map()) :: map()
  def serialize_public(state) when is_map(state) do
    serialize(state)
  end

  @doc """
  Serializes a game state for a viewer at an authorized seat, or publicly by default.

  Only the viewer's hand contains card identities. All players have an
  authoritative card_count; hidden hands are nil. The position must come from
  the server's room membership, never from client input.

  Converts complex Elixir structs and tuples (cards, bids, tricks) into
  JSON-compatible formats (maps, lists, strings).

  ## Examples

      iex> serialize(game_state)
      %{phase: :bidding, players: %{...}, ...}
  """
  @spec serialize(map(), atom() | nil) :: map()
  def serialize(state, position \\ nil) when is_map(state) do
    pace = Map.get(Map.get(state, :config, %{}), :pace, :quick)

    %{
      phase: state.phase,
      pace: Atom.to_string(pace),
      awaiting_continue: pace == :own and state.phase == :hand_complete,
      hand_number: Map.get(state, :hand_number),
      variant: Map.get(state, :variant),
      config: Map.get(state, :config, %{}),
      current_turn: Map.get(state, :current_turn),
      current_dealer: Map.get(state, :current_dealer),
      players:
        serialize_players(
          Map.get(state, :players, %{}),
          position,
          second_deal(state),
          picking(state)
        ),
      bids: serialize_bids(Map.get(state, :bids, [])),
      highest_bid: serialize_highest_bid(Map.get(state, :highest_bid)),
      bidding_team: Map.get(state, :bidding_team),
      trump_suit: Map.get(state, :trump_suit),
      killed_cards: killed_cards(state),
      tricks: serialize_tricks(Map.get(state, :tricks, [])),
      current_trick: serialize_current_trick(Map.get(state, :current_trick)),
      current_trick_details: serialize_current_trick_details(state),
      trick_number: Map.get(state, :trick_number),
      hand_points: Map.get(state, :hand_points, %{}),
      last_hand: serialize_last_hand(Map.get(state, :last_hand)),
      hand_history: Enum.map(Map.get(state, :hand_history, []), &serialize_hand/1),
      scores: Map.get(state, :cumulative_scores, %{}),
      cumulative_scores: Map.get(state, :cumulative_scores, %{}),
      winner: Map.get(state, :winner),
      dealer_selection_cuts: serialize_position_cards(Map.get(state, :dealer_selection_cuts))
    }
  end

  defp serialize_players(players, viewer_position, second_deal, picking) do
    Map.new(players, fn {position, player} ->
      visible? = position == viewer_position and viewer_position != nil

      player =
        player
        |> serialize_player(visible?, Map.get(second_deal, position))
        |> hide_pool(position == picking and not visible?)

      {position, player}
    end)
  end

  # A dealer picking from the pack holds their whole pool: its size would tell
  # the table how many trumps they kept, the dealer's edge. Only they see it
  # while they choose.
  defp picking(%{phase: :second_deal} = state), do: Map.get(state, :current_dealer)
  defp picking(_state), do: nil

  defp hide_pool(player, true), do: %{player | card_count: nil}
  defp hide_pool(player, false), do: player

  # What each seat kept, threw and drew in the second deal: everyone at the
  # table sees it, so the client can play it out card by card.
  defp second_deal(%GameState{} = state),
    do: Map.merge(SeatView.second_deal_counts(state), dealer_throw(state))

  defp second_deal(_state), do: %{}

  # Once the dealer is down to six, the table counts the backs of what they
  # threw from the pool they took up; a dealer who took nothing up threw
  # nothing. Never their kept count, never the faces.
  defp dealer_throw(%GameState{phase: :playing, current_dealer: dealer, dealer_pool_size: pool}),
    do: %{dealer => %{kept: nil, discarded: max((pool || 0) - 6, 0), drawn: nil}}

  defp dealer_throw(_state), do: %{}

  # Trumps killed over six are public by the rules: face up for every viewer
  # until the hand ends.
  defp killed_cards(%GameState{phase: :playing} = state) do
    Map.new(SeatView.killed_cards(state), fn {pos, cards} -> {pos, serialize_cards(cards)} end)
  end

  defp killed_cards(_state), do: %{}

  defp serialize_player(player, visible?, second_deal) do
    hand = Map.get(player, :hand, [])
    folded = Map.get(player, :revealed_cards, [])
    eliminated? = Map.get(player, :eliminated?, false)

    %{
      position: Map.get(player, :position),
      team: Map.get(player, :team),
      hand: if(visible?, do: serialize_cards(hand), else: nil),
      card_count: length(hand),
      tricks_won: Map.get(player, :tricks_won, 0),
      eliminated: eliminated?,
      revealed_cards: if(visible?, do: serialize_cards(folded), else: []),
      folded_count: if(eliminated?, do: length(folded), else: 0),
      kept_count: second_deal && second_deal.kept,
      discarded_count: second_deal && second_deal.discarded,
      drawn_count: second_deal && second_deal.drawn
    }
  end

  @doc """
  Serializes a list of cards (tuples) into JSON-safe maps.
  """
  @spec serialize_cards(list()) :: list()
  def serialize_cards(cards) when is_list(cards) do
    Enum.map(cards, &serialize_card/1)
  end

  @doc """
  Serializes a card tuple into a map.
  """
  @spec serialize_card({integer(), atom()}) :: map()
  def serialize_card({rank, suit}) do
    %{rank: rank, suit: suit}
  end

  @doc """
  Serializes a list of bids.
  """
  @spec serialize_bids(list()) :: list()
  def serialize_bids(bids) when is_list(bids) do
    Enum.map(bids, &serialize_bid/1)
  end

  @doc """
  Serializes a single bid.
  """
  @spec serialize_bid(map() | any()) :: map() | nil
  def serialize_bid(%{position: position, amount: amount}) do
    %{position: position, amount: amount}
  end

  def serialize_bid(_), do: nil

  @doc """
  Serializes the highest bid tuple.
  """
  @spec serialize_highest_bid({atom(), integer()} | nil) :: map() | nil
  def serialize_highest_bid(nil), do: nil

  def serialize_highest_bid({position, amount}) do
    %{position: position, amount: amount}
  end

  @doc """
  Serializes a list of completed tricks.

  Frontend expects: `[%{cards: [%{player: position, card: card}], winner: position}]`
  """
  @spec serialize_tricks(list()) :: list()
  def serialize_tricks(tricks) when is_list(tricks) do
    Enum.map(tricks, &serialize_trick/1)
  end

  @spec serialize_trick(map() | nil) :: map() | nil
  def serialize_trick(nil), do: nil

  def serialize_trick(trick) when is_map(trick) do
    plays = serialize_plays(Map.get(trick, :plays, []))

    %{
      number: Map.get(trick, :number),
      leader: Map.get(trick, :leader),
      plays: plays,
      cards: plays,
      winner: Map.get(trick, :winner),
      points: Map.get(trick, :points, 0),
      two_of_trump: Map.get(trick, :two_of_trump)
    }
  end

  # The finished hand's bids and tricks use the live `bids` and `tricks` shapes;
  # its trump is the suit atom, as the live `trump_suit` is.
  @spec serialize_last_hand(map() | nil) :: map() | nil
  defp serialize_last_hand(nil), do: nil

  defp serialize_last_hand(last_hand) when is_map(last_hand) do
    last_hand
    |> serialize_hand()
    |> Map.put(:bids, serialize_bids(Map.get(last_hand, :bids, [])))
    |> Map.put(:trump, Map.get(last_hand, :trump))
    |> Map.put(:tricks, serialize_tricks(Map.get(last_hand, :tricks, [])))
  end

  # A scored hand's point cards use the payload card shape.
  @spec serialize_hand(map()) :: map()
  defp serialize_hand(hand) do
    Map.update(hand, :point_cards, [], fn point_cards ->
      Enum.map(point_cards, &%{&1 | card: serialize_card(&1.card)})
    end)
  end

  defp serialize_current_trick_details(%{current_trick: trick} = state) when not is_nil(trick) do
    signals = Pidro.Finnish.Scorer.trick_signals(trick, state.trump_suit, state.variant)

    winning =
      case signals.winning do
        nil -> nil
        %{position: position, card: card} -> %{position: position, card: serialize_card(card)}
      end

    trick
    |> serialize_trick()
    |> Map.merge(%{signals | winning: winning})
  end

  defp serialize_current_trick_details(_state), do: nil

  @doc """
  Serializes the current trick as a flat array of plays.

  Frontend expects: `[%{player: position, card: card}]`
  """
  @spec serialize_current_trick(map() | nil) :: list()
  def serialize_current_trick(nil), do: []

  def serialize_current_trick(trick) when is_map(trick) do
    serialize_plays(Map.get(trick, :plays, []))
  end

  @spec serialize_plays(list()) :: list()
  def serialize_plays(plays) when is_list(plays) do
    plays
    |> Enum.map(&serialize_play/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec serialize_play(tuple() | map() | any()) :: map() | nil
  def serialize_play({position, card}) do
    serialized_card = serialize_card(card)
    %{player: position, position: position, card: serialized_card}
  end

  def serialize_play(%{position: position, card: card}) do
    serialized_card = serialize_card(card)
    %{player: position, position: position, card: serialized_card}
  end

  def serialize_play(%{player: position, card: card}) do
    serialized_card = serialize_card(card)
    %{player: position, position: position, card: serialized_card}
  end

  def serialize_play(_), do: nil

  @doc """
  Serializes a list of legal actions from the engine into JSON-safe maps.

  ## Examples

      iex> serialize_legal_actions([{:bid, 7}, :pass])
      [%{type: "bid", amount: 7}, %{type: "pass"}]
  """
  @spec serialize_legal_actions(list()) :: list()
  def serialize_legal_actions(actions) when is_list(actions) do
    Enum.map(actions, &serialize_legal_action/1)
  end

  defp serialize_legal_action({:bid, amount}), do: %{type: "bid", amount: amount}
  defp serialize_legal_action(:pass), do: %{type: "pass"}

  defp serialize_legal_action({:declare_trump, suit}),
    do: %{type: "declare_trump", suit: suit}

  defp serialize_legal_action({:play_card, {rank, suit}}),
    do: %{type: "play_card", card: %{rank: rank, suit: suit}}

  defp serialize_legal_action({:select_hand, _}), do: %{type: "select_hand"}
  defp serialize_legal_action(:select_dealer), do: %{type: "select_dealer"}
  defp serialize_legal_action(action), do: %{type: inspect(action)}

  @spec serialize_position_cards(%{atom() => {integer(), atom()}} | nil) :: map() | nil
  defp serialize_position_cards(nil), do: nil

  defp serialize_position_cards(position_cards) when is_map(position_cards) do
    Map.new(position_cards, fn {position, card} -> {position, serialize_card(card)} end)
  end
end
