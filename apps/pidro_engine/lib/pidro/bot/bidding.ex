defmodule Pidro.Bot.Bidding do
  @moduledoc """
  How the rulebook bot bids and names trump.

  Each suit gets a point estimate from the nine-card hand, counting the
  same-colour Five as trump (see `Pidro.Bot.Thresholds`). The Ace counts
  more with the King, or with two of the King, Queen and Jack; a Five counts
  for little without the cover of four trumps or of the Ace with three, and
  a pass it costs says so. The estimate is a
  ceiling, not the bid. A made contract scores the points the team took and
  a failed one loses the bid, so a higher bid never earns a point: it only
  raises the penalty and tells the table what the hand holds. Bidding is one
  round with the dealer last, so the bot bids the lowest legal bid its
  estimate covers, in Finnish nearly covers, and passes otherwise.

  The dealer has nothing left to shut out and takes the minimum; one forced
  to bid takes it whatever it holds. Any other seat has an opponent still to
  speak, and with an estimate the shut-out margin above the minimum it bids
  one more, never two. Over a partner's standing bid it raises by one only
  when its estimate clears that bid by the partner margin, and passes
  otherwise. Declaring trump recomputes the best suit from the current hand,
  so a substitute that inherits an undeclared bid names its own best suit.

  Finnish estimates include a small trump-length bonus. The Finnish bot
  opens or outbids an opponent at the minimum on an estimate up to the
  volunteer margin short of it, so fewer hands end in a forced dealer 6, and
  it takes a cheap contract from an opponent's 6 or 7 on an estimate half a
  point short, inside the volunteer margin, so that allowance only changes
  the reason. Neither raises a partner or bids above the minimum.
  Louisiana estimates without the length bonus and bids by the same rules,
  without either allowance. The same view and legal actions always give the
  same bid.
  """

  alias Pidro.Bot.Thresholds
  alias Pidro.Core.{Card, SeatView, Types}

  @type decision :: {Types.action(), String.t()}

  @honours %{14 => "Ace", 13 => "King", 12 => "Queen", 11 => "Jack"}

  @doc """
  Returns the bid estimate of `hand` with `suit` as trump.

  ## Parameters

  - `hand` - the cards held, trump or not
  - `suit` - the candidate trump suit
  - `dealer?` - whether the bidder is the dealer, who robs the pack
  - `variant` - defaults to Finnish; Louisiana has no length bonus

  ## Examples

      iex> hand = [{11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}, {5, :hearts}]
      iex> Pidro.Bot.Bidding.estimate(hand, :hearts, false)
      4.75
  """
  @spec estimate([Types.card()], Types.suit(), boolean(), atom()) :: float()
  def estimate(hand, suit, dealer?, variant \\ :finnish) do
    trumps = trumps(hand, suit)

    (sure_points(trumps, suit) + half_credit(trumps, suit) + fives(trumps, suit) +
       control(trumps, suit) + length_bonus(trumps, variant) +
       if(dealer?, do: t(:dealer_bonus), else: 0)) * 1.0
  end

  @doc """
  Returns the best suit for `hand` and its estimate.

  Equal estimates resolve in the fixed suit order hearts, diamonds, clubs,
  spades, the same order the timer auto-play uses. The optional variant
  defaults to Finnish, as in `estimate/4`.

  ## Examples

      iex> Pidro.Bot.Bidding.best_suit([{14, :spades}, {13, :spades}, {5, :spades}], false)
      {:spades, 9.25}
  """
  @spec best_suit([Types.card()], boolean(), atom()) :: {Types.suit(), float()}
  def best_suit(hand, dealer?, variant \\ :finnish) do
    Types.all_suits()
    |> Enum.map(&{&1, estimate(hand, &1, dealer?, variant)})
    |> Enum.reduce(fn {_suit, est} = candidate, {_best, best_est} = best ->
      if est > best_est, do: candidate, else: best
    end)
  end

  @doc """
  Chooses a bid or a pass from `legal` for the seat in `view`.

  ## Returns

  `{action, reason}` where `action` is a member of `legal`.
  """
  @spec decide_bid(SeatView.t(), [Types.action()]) :: decision()
  def decide_bid(%SeatView{} = view, legal) do
    dealer? = view.current_dealer == view.position
    {suit, est} = best_suit(own_hand(view), dealer?, view.variant)
    trumps = trumps(own_hand(view), suit)
    bare = bare_fives(trumps, suit)
    {lowest, highest} = Enum.min_max(for({:bid, n} <- legal, do: n), fn -> {nil, nil} end)
    worth = "#{suit_name(suit)} are worth about #{trunc(est)}#{holding_phrase(trumps, suit)}"
    mine = "my #{String.downcase(suit_name(suit))} are worth about #{trunc(est)}"

    cond do
      lowest == nil ->
        {:pass, "No higher bid is left, so I pass."}

      :pass not in legal ->
        {{:bid, lowest},
         "Everyone passed, so as dealer I must bid and take the minimum #{lowest}."}

      partner_bid = partner_standing_bid(view) ->
        if est >= partner_bid + t(:overbid_partner_margin) do
          {{:bid, lowest}, "Partner bid #{partner_bid} and #{mine}, so I raise to #{lowest}."}
        else
          {:pass, "Partner's #{partner_bid} stands; #{mine}, not enough to go over it."}
        end

      contest?(view, est, lowest) ->
        {{:bid, lowest},
         "#{worth}; taking the cheap contract from the opponents is worth #{lowest}."}

      est < lowest - volunteer_margin(view.variant) and
          est + bare * (t(:five_protected) - t(:five_unprotected)) >=
            lowest - volunteer_margin(view.variant) ->
        {:pass,
         "#{if bare == 1, do: "My Five has", else: "My Fives have"} no cover, " <>
           "so #{String.downcase(suit_name(suit))} are worth about #{trunc(est)}; I pass."}

      est < lowest - volunteer_margin(view.variant) ->
        {:pass,
         "My best suit is not enough: #{suit_name(suit)} are worth about #{trunc(est)} points, " <>
           "below the #{lowest} needed, so I pass."}

      not dealer? and est >= lowest + t(:shut_out_margin) ->
        amount = min(lowest + 1, highest)
        {{:bid, amount}, "#{worth}, so I bid #{amount} to keep #{still_to_speak(view)} out."}

      est >= lowest ->
        {{:bid, lowest}, "#{worth}, so I bid the #{lowest} that takes it."}

      true ->
        {{:bid, lowest}, "#{worth}, close enough to take the #{lowest}."}
    end
  end

  @doc """
  Names trump from `legal` for the seat in `view`: the best suit of the hand
  it holds now.

  ## Returns

  `{action, reason}` where `action` is a member of `legal`.
  """
  @spec decide_trump(SeatView.t(), [Types.action()]) :: decision()
  def decide_trump(%SeatView{} = view, legal) do
    dealer? = view.current_dealer == view.position
    {suit, est} = best_suit(own_hand(view), dealer?, view.variant)

    if {:declare_trump, suit} in legal do
      {{:declare_trump, suit},
       "I name #{suit_name(suit)}, my strongest suit at about #{trunc(est)} points."}
    else
      {hd(legal), "My strongest suit cannot be named, so I take the first one offered."}
    end
  end

  # Seats alternate teams and the dealer speaks last, so every seat but the
  # dealer has an opponent still to speak: the dealer when it is next, the
  # seat on the left when the dealer is partner, both opponents otherwise.
  defp still_to_speak(%SeatView{position: me, current_dealer: dealer}) do
    cond do
      Types.next_position(me) == dealer -> "the dealer"
      Types.partner_position(me) == dealer -> "the opponent on my left"
      true -> "the opponents"
    end
  end

  defp partner_standing_bid(%SeatView{} = view) do
    case view.highest_bid do
      {pos, amount} -> if pos == Types.partner_position(view.position), do: amount
      nil -> nil
    end
  end

  defp contest?(%SeatView{variant: :finnish, highest_bid: {_, amount}}, est, minimum)
       when amount in [6, 7] do
    est < minimum and est + t(:cheap_contract_margin) >= minimum
  end

  defp contest?(_view, _est, _minimum), do: false

  defp volunteer_margin(:finnish), do: t(:volunteer_margin)
  defp volunteer_margin(_variant), do: 0

  defp length_bonus(trumps, :finnish) do
    min(max(length(trumps) - 2, 0) * t(:trump_length), t(:trump_length_cap))
  end

  defp length_bonus(_trumps, _variant), do: 0

  defp sure_points(trumps, suit) do
    if({14, suit} in trumps, do: t(:ace), else: 0) + if({2, suit} in trumps, do: t(:two), else: 0)
  end

  defp half_credit(trumps, suit) do
    t(:jack_or_ten) * Enum.count([{11, suit}, {10, suit}], &(&1 in trumps))
  end

  defp fives(trumps, suit) do
    value = if covered?(trumps, suit), do: t(:five_protected), else: t(:five_unprotected)
    value * Enum.count(trumps, &match?({5, _}, &1))
  end

  defp bare_fives(trumps, suit) do
    if covered?(trumps, suit), do: 0, else: Enum.count(trumps, &match?({5, _}, &1))
  end

  # Four trumps cover a Five, and so does the Ace with three; a King can
  # fall to the Ace with the Five under it.
  defp covered?(trumps, suit) do
    length(trumps) >= t(:five_protection_trumps) or
      ({14, suit} in trumps and length(trumps) >= t(:five_protection_trumps_with_ace))
  end

  # The Ace with the King, or with two of the King, Queen and Jack, counts by
  # the holding table; otherwise the Ace and King count alone.
  defp control(trumps, suit) do
    ace? = {14, suit} in trumps
    king? = {13, suit} in trumps

    cond do
      held = holding(trumps, suit) ->
        elem(held, 1)

      ace? and king? ->
        t(:control_ace_king)

      ace? or king? ->
        if length(trumps) >= t(:control_one_honour_min_trumps),
          do: t(:control_one_honour),
          else: 0

      true ->
        0
    end
  end

  defp holding(trumps, suit) do
    if length(trumps) >= t(:control_one_honour_min_trumps) do
      Enum.find(Thresholds.holdings(), fn {ranks, _bonus} ->
        Enum.all?(ranks, &({&1, suit} in trumps))
      end)
    end
  end

  defp holding_phrase(trumps, suit) do
    case holding(trumps, suit) do
      {ranks, _bonus} ->
        {last, rest} = ranks |> Enum.map(&@honours[&1]) |> List.pop_at(-1)
        " with the " <> Enum.join(rest, ", ") <> " and " <> last

      nil ->
        ""
    end
  end

  defp trumps(hand, suit), do: Enum.filter(hand, &Card.is_trump?(&1, suit))

  defp own_hand(%SeatView{hand: hand}), do: hand

  defp suit_name(suit), do: Types.suit_to_name(suit)

  defp t(name), do: Thresholds.get(name)
end
