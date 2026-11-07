defmodule Pidro.Bot.Play do
  @moduledoc """
  How the rulebook bot chooses a card.

  Following and leading each have an ordered list of rules. The first rule
  that applies picks the card and says why; the last rule always applies.
  The rules look at the partner only as a seat, so the bot plays the same
  conventions with a human or a bot partner.

  Finnish Pidro only; see `Pidro.Bot.Rulebook` for the supported-variant
  contract.

  ## Following

  1. Only one legal card: play it.
  2. The trick is safe for the bot's side: feed it a Five, off-Five first,
     otherwise play the lowest card.
  3. An opponent's Five is on an unsafe trick and the bot's highest trump
     beats the current winner: play that trump.
  4. Partner is winning a trick that holds points but is not safe: play the
     lowest card that makes it safe, if there is one.
  5. The opponents are winning a trick that holds points and the bot can
     beat them: play the lowest card that wins.
  6. Otherwise play the lowest non-point card, then the 2, then the lowest
     point card, a Five last.

  ## Leading

  1. Only Fives in hand: lead the off-Five before the Five.
  2. On the bidding side, opening with the Ace and four or more trumps but
     not both the King and Queen: lead the 2, otherwise the lowest non-point
     trump, and keep the Ace to take a Five later.
  3. On the bidding side, with a top trump nothing can beat: lead it, except
     the Ace on the opening lead from fewer than four trumps without the King,
     and never a Five while another card is held.
  4. Otherwise lead the lowest non-point trump, then the 2, then the lowest
     point card that is not a Five.
  """

  alias Pidro.Bot.Knowledge
  alias Pidro.Core.{Card, SeatView, Types}

  @type decision :: {Types.action(), String.t()}
  @typep card :: Types.card()
  @typep rule_result :: {card(), String.t()} | nil

  @follow_rules [
    :only_card,
    :feed_safe_trick,
    :stop_opponent_five,
    :secure_partner_points,
    :take_points,
    :play_low
  ]

  @lead_rules [:only_fives, :keep_ace, :lead_top, :lead_low]

  @doc """
  Chooses a card from `legal` for the seat in `view`.

  ## Returns

  `{{:play_card, card}, reason}` where the action is a member of `legal`.
  """
  @spec decide(SeatView.t(), [Types.action()]) :: decision()
  def decide(%SeatView{} = view, legal) do
    trump = view.trump_suit

    cards =
      for {:play_card, card} <- legal do
        card
      end
      |> Knowledge.sort_ascending(trump)

    rules = if Knowledge.leading?(view), do: @lead_rules, else: @follow_rules
    {card, reason} = Enum.find_value(rules, &apply_rule(&1, view, cards))
    {{:play_card, card}, reason}
  end

  @doc """
  Orders cards for throwing away: non-point cards lowest first, then the 2
  (whose point stays with the side that played it), then the other point
  cards lowest first, and the Fives last, the off-Five before the Five.

  ## Examples

      iex> cards = [{5, :hearts}, {14, :hearts}, {2, :hearts}, {9, :hearts}, {5, :diamonds}, {10, :hearts}]
      iex> Pidro.Bot.Play.discard_order(cards, :hearts)
      [{9, :hearts}, {2, :hearts}, {10, :hearts}, {14, :hearts}, {5, :diamonds}, {5, :hearts}]
  """
  @spec discard_order([card()], Types.suit()) :: [card()]
  def discard_order(cards, trump) do
    sorted = Knowledge.sort_ascending(cards, trump)
    {fives, rest} = Enum.split_with(sorted, &Knowledge.five?(&1, trump))
    {points, plain} = Enum.split_with(rest, &Card.is_point_card?(&1, trump))
    {twos, other_points} = Enum.split_with(points, &(&1 == {2, trump}))
    plain ++ twos ++ other_points ++ fives
  end

  # --- Following --------------------------------------------------------------

  @spec apply_rule(atom(), SeatView.t(), [card()]) :: rule_result()
  defp apply_rule(:only_card, _view, [card]), do: {card, "It is my only trump."}
  defp apply_rule(:only_card, _view, _cards), do: nil

  defp apply_rule(:feed_safe_trick, view, cards) do
    if Knowledge.safe_trick?(view) do
      {_pos, winning} = Knowledge.current_winner(view)

      case five_to_feed(cards, view.trump_suit) do
        nil ->
          low = lowest(cards, view)

          {low,
           "Partner's #{name(winning)} cannot be beaten, " <>
             "and with no Five to give I play my #{name(low)}."}

        five ->
          {five, "Partner's #{name(winning)} cannot be beaten, so I give it my #{name(five)}."}
      end
    end
  end

  defp apply_rule(:stop_opponent_five, view, cards) do
    high = List.last(cards)

    if Knowledge.opponent_five_on_trick?(view) and not Knowledge.safe_trick?(view) and
         Knowledge.wins_trick?(view, high) do
      {high,
       "An opponent put a Five on the trick, so I take it with my highest trump, the #{name(high)}."}
    end
  end

  defp apply_rule(:secure_partner_points, view, cards) do
    {winner, winning} = Knowledge.current_winner(view)
    points = Knowledge.points_on_trick(view)

    if winner == Knowledge.partner(view) and points > 0 and not Knowledge.safe_trick?(view) do
      case Enum.find(cards, &Knowledge.safe_after?(view, &1)) do
        nil ->
          nil

        card ->
          {card,
           "Partner's #{name(winning)} could still be beaten with #{points} points on the trick, " <>
             "so I cover it with my #{name(card)}."}
      end
    end
  end

  defp apply_rule(:take_points, view, cards) do
    {winner, winning} = Knowledge.current_winner(view)
    points = Knowledge.points_on_trick(view)
    opponent? = Types.position_to_team(winner) != Knowledge.my_team(view)

    if opponent? and points > 0 do
      case Enum.find(cards, &Knowledge.wins_trick?(view, &1)) do
        nil ->
          nil

        card ->
          {card,
           "The opponents' #{name(winning)} holds #{points} points, " <>
             "and my #{name(card)} is the cheapest card that takes it."}
      end
    end
  end

  defp apply_rule(:play_low, view, cards) do
    low = lowest(cards, view)
    {winner, _winning} = Knowledge.current_winner(view)

    reason =
      cond do
        winner == Knowledge.partner(view) ->
          "Partner is winning but the trick is not safe, so I play low with my #{name(low)}."

        Enum.any?(cards, &Knowledge.wins_trick?(view, &1)) ->
          "There is nothing on the trick worth taking, so I play my lowest card, the #{name(low)}."

        true ->
          "I cannot win this trick, so I play my lowest card, the #{name(low)}."
      end

    {low, reason}
  end

  # --- Leading ----------------------------------------------------------------

  defp apply_rule(:only_fives, view, cards) do
    trump = view.trump_suit

    if Enum.all?(cards, &Knowledge.five?(&1, trump)) do
      [five | _] = discard_order(cards, trump)
      {five, "I hold only Fives, so I lead the #{name(five)}."}
    end
  end

  defp apply_rule(:keep_ace, view, cards) do
    trump = view.trump_suit

    low =
      if {2, trump} in cards,
        do: {2, trump},
        else: Enum.find(cards, &(not Card.is_point_card?(&1, trump)))

    if Knowledge.bidding_side?(view) and Knowledge.opening_trick?(view) and
         {14, trump} in cards and length(cards) >= 4 and low != nil and
         not ({13, trump} in cards and {12, trump} in cards) do
      {low, "I lead my #{name(low)} to draw trumps and keep the Ace for a Five."}
    end
  end

  defp apply_rule(:lead_top, view, cards) do
    top = List.last(cards)
    trump = view.trump_suit

    cond do
      not Knowledge.bidding_side?(view) -> nil
      not Knowledge.unbeatable?(view, top) -> nil
      Knowledge.five?(top, trump) -> nil
      ace_too_short?(view, cards, top) -> nil
      true -> {top, "My #{name(top)} is the highest trump left, so I lead it."}
    end
  end

  defp apply_rule(:lead_low, view, cards) do
    low = lowest(cards, view)

    reason =
      if Knowledge.bidding_side?(view) do
        "I lead low with my #{name(low)} and keep my higher trumps for later."
      else
        "On defence I lead a low trump, the #{name(low)}."
      end

    {low, reason}
  end

  # Opening with the Ace from fewer than four trumps without the King is a
  # known mistake.
  defp ace_too_short?(view, cards, {14, _suit}) do
    Knowledge.opening_trick?(view) and length(cards) < 4 and
      {13, view.trump_suit} not in cards
  end

  defp ace_too_short?(_view, _cards, _top), do: false

  defp five_to_feed(cards, trump) do
    Enum.find([{5, Card.same_color_suit(trump)}, {5, trump}], &(&1 in cards))
  end

  defp lowest(cards, view), do: cards |> discard_order(view.trump_suit) |> hd()

  defp name(card), do: Types.card_to_string(card)
end
