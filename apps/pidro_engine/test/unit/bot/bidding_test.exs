defmodule Pidro.Bot.BiddingTest do
  use ExUnit.Case, async: true

  import Pidro.Test.Scenario, only: [suit: 2]

  alias Pidro.Bot.{Bidding, Knowledge, Thresholds}
  alias Pidro.Core.SeatView
  alias Pidro.Test.{GameTrace, Scenario}

  doctest Pidro.Bot.Bidding

  # Nine cards: the given cards plus low, pointless filler in the black suits.
  defp hand(cards) do
    filler = suit(:clubs, [3, 4, 7, 8]) ++ suit(:spades, [6, 7, 8, 9])
    cards ++ Enum.take(filler -- cards, 9 - length(cards))
  end

  # A-J-10-7-5-2 of hearts and the 5 of diamonds: about 11 points, 12 as dealer.
  defp big, do: hand(suit(:hearts, [14, 11, 10, 7, 5, 2]) ++ [{5, :diamonds}])

  defp decide(state), do: Bidding.decide_bid(Scenario.view(state), Scenario.legal(state))

  describe "the estimate is a ceiling, not the bid" do
    test "a dealer over a 6 with a 12-point hand bids 7" do
      assert trunc(Bidding.estimate(big(), :hearts, true)) == 12

      state =
        Scenario.bidding(
          me: :west,
          dealer: :west,
          bids: [north: :pass, east: :pass, south: 6],
          hand: big()
        )

      assert {{:bid, 7}, reason} = decide(state)
      assert reason == "Hearts are worth about 12, so I bid the 7 that takes it."
    end

    test "a forced dealer with a 12-point hand bids 6" do
      state =
        Scenario.bidding(
          me: :west,
          dealer: :west,
          bids: [north: :pass, east: :pass, south: :pass],
          hand: big()
        )

      assert {{:bid, 6}, _} = decide(state)
    end

    test "third to speak after two passes bids one over the minimum to keep the dealer out" do
      assert trunc(Bidding.estimate(big(), :hearts, false)) == 11

      state =
        Scenario.bidding(
          me: :south,
          dealer: :west,
          bids: [north: :pass, east: :pass],
          hand: big()
        )

      assert {{:bid, 7}, reason} = decide(state)
      assert reason == "Hearts are worth about 11, so I bid 7 to keep the dealer out."
    end

    test "below the shut-out margin the bot bids the minimum" do
      cards = hand(suit(:hearts, [14, 5, 2]))
      assert Bidding.estimate(cards, :hearts, false) == 7.25

      state =
        Scenario.bidding(
          me: :south,
          dealer: :west,
          bids: [north: :pass, east: :pass],
          hand: cards
        )

      assert {{:bid, 6}, reason} = decide(state)
      assert reason == "Hearts are worth about 7, so I bid the 6 that takes it."

      first = Scenario.bidding(me: :north, dealer: :west, hand: cards)
      assert {{:bid, 6}, _} = decide(first)
    end

    test "first to speak shuts out the opponents by one, never more" do
      state = Scenario.bidding(me: :north, dealer: :west, hand: big())
      assert {{:bid, 7}, reason} = decide(state)
      assert reason =~ "so I bid 7 to keep the opponents out."
    end

    test "the dealer's partner shuts out the one opponent still to speak" do
      state = Scenario.bidding(me: :east, dealer: :west, bids: [north: :pass], hand: big())
      assert {{:bid, 7}, reason} = decide(state)
      assert reason =~ "so I bid 7 to keep the opponent on my left out."
    end

    test "the shut-out takes an estimate three over the minimum" do
      three_over = hand(suit(:hearts, [13, 11, 5]) ++ [{5, :diamonds}])
      just_short = hand(suit(:hearts, [14, 11, 10, 5, 2]))
      assert Bidding.estimate(three_over, :hearts, false) == 9.0
      assert Bidding.estimate(just_short, :hearts, false) == 8.75

      assert {{:bid, 7}, _} =
               decide(Scenario.bidding(me: :north, dealer: :west, hand: three_over))

      assert {{:bid, 6}, _} =
               decide(Scenario.bidding(me: :north, dealer: :west, hand: just_short))

      over_seven = Scenario.bidding(me: :east, dealer: :west, bids: [north: 7], hand: big())
      assert {{:bid, 9}, _} = decide(over_seven)
    end

    test "a partner's 7 stands against an 8-point hand; a 9-point hand raises it by one" do
      eight = hand(suit(:hearts, [14, 11, 5, 2]))
      nine = hand(suit(:hearts, [13, 5, 2]) ++ [{5, :diamonds}])
      assert trunc(Bidding.estimate(eight, :hearts, false)) == 8
      assert trunc(Bidding.estimate(nine, :hearts, false)) == 9

      state = Scenario.bidding(me: :south, bids: [north: 7, east: :pass], hand: eight)
      assert {:pass, reason} = decide(state)

      assert reason ==
               "Partner's 7 stands; my hearts are worth about 8, not enough to go over it."

      state = Scenario.bidding(me: :south, bids: [north: 7, east: :pass], hand: nine)
      assert {{:bid, 8}, reason} = decide(state)
      assert reason == "Partner bid 7 and my hearts are worth about 9, so I raise to 8."
    end

    test "the bid never passes the highest legal bid" do
      view = Scenario.view(Scenario.bidding(me: :north, dealer: :west, hand: big()))
      assert {{:bid, 6}, _} = Bidding.decide_bid(view, [{:bid, 6}, :pass])
    end

    test "Louisiana bids the minimum of 7, one more to shut out, and raises a partner by one" do
      louisiana = fn state ->
        %{state | variant: :louisiana, config: %{state.config | min_bid: 7}}
      end

      assert Bidding.estimate(big(), :hearts, false, :louisiana) == 11.0

      first = louisiana.(Scenario.bidding(me: :north, dealer: :west, hand: big()))
      assert {{:bid, 8}, _} = decide(first)

      dealer =
        louisiana.(
          Scenario.bidding(
            me: :west,
            dealer: :west,
            bids: [north: :pass, east: :pass, south: 7],
            hand: big()
          )
        )

      assert {{:bid, 8}, _} = decide(dealer)

      nine = hand(suit(:hearts, [13, 5, 2]) ++ [{5, :diamonds}])
      assert Bidding.estimate(nine, :hearts, false, :louisiana) == 9.0

      partner =
        louisiana.(Scenario.bidding(me: :south, bids: [north: 7, east: :pass], hand: nine))

      assert {{:bid, 8}, _} = decide(partner)
    end
  end

  describe "Finnish bidding competition" do
    test "volunteers the minimum on an estimate up to a point short of it, and passes below" do
      inside = hand(suit(:hearts, [10, 7, 5, 2]))
      outside = hand(suit(:hearts, [11, 10, 7, 6, 5]))
      assert Thresholds.get(:volunteer_margin) == 1.0
      assert Bidding.estimate(inside, :hearts, false) == 5.0
      assert Bidding.estimate(outside, :hearts, false) == 4.75

      assert {{:bid, 6}, reason} = decide(Scenario.bidding(me: :north, hand: inside))
      assert reason == "Hearts are worth about 5, close enough to take the 6."
      assert {:pass, _} = decide(Scenario.bidding(me: :north, hand: outside))

      over_opponent = Scenario.bidding(me: :east, bids: [north: 6], hand: inside)
      assert {:pass, _} = decide(over_opponent)

      dealer =
        Scenario.bidding(me: :west, bids: [north: :pass, east: :pass, south: 6], hand: inside)

      assert Bidding.estimate(inside, :hearts, true) == 6.0
      assert {{:bid, 7}, "Hearts are worth about 6, close enough to take the 7."} = decide(dealer)
    end

    test "length makes a protected Five worth contesting an opponent's 6" do
      cards = hand(suit(:hearts, [14, 8, 7, 5]))
      assert Bidding.estimate(cards, :hearts, false) == 6.5

      state = Scenario.bidding(me: :east, bids: [north: 6], hand: cards)
      assert {{:bid, 7}, _} = decide(state)

      weak = hand(suit(:hearts, [14, 11, 10, 4]))
      assert Bidding.estimate(weak, :hearts, false) == 4.5
      assert {:pass, _} = decide(Scenario.bidding(me: :east, bids: [north: 6], hand: weak))
    end

    test "raises partner with a better hand, never with the competition allowance" do
      strong = hand(suit(:hearts, [14, 11, 10, 5, 2]))
      assert Bidding.estimate(strong, :hearts, false) == 8.75
      state = Scenario.bidding(me: :south, bids: [north: 6, east: :pass], hand: strong)
      assert {{:bid, 7}, _} = decide(state)

      close = hand(suit(:hearts, [14, 8, 7, 5]))
      state = Scenario.bidding(me: :south, bids: [north: 6, east: :pass], hand: close)
      assert {:pass, _} = decide(state)

      state = Scenario.bidding(me: :south, bids: [north: 7, east: :pass], hand: strong)
      assert {:pass, _} = decide(state)
    end

    test "contests a 7 at the half-point boundary; over an 8 only the volunteer margin applies" do
      cards = hand(suit(:hearts, [14, 11, 10, 5]))
      assert Bidding.estimate(cards, :hearts, false) == 7.5
      state = Scenario.bidding(me: :east, bids: [north: 7], hand: cards)
      assert {{:bid, 8}, reason} = decide(state)
      assert reason =~ "cheap contract"

      cards = hand(suit(:hearts, [14, 11, 10, 5, 2]))
      assert Bidding.estimate(cards, :hearts, false) == 8.75
      state = Scenario.bidding(me: :east, bids: [north: 8], hand: cards)
      assert {{:bid, 9}, reason} = decide(state)
      assert reason == "Hearts are worth about 8, close enough to take the 9."
    end

    test "Louisiana takes neither the contest allowance nor the partner raise" do
      close = hand(suit(:hearts, [14, 8, 7, 5]))
      strong = hand(suit(:hearts, [14, 5, 2]))
      assert Bidding.estimate(close, :hearts, false, :louisiana) == 6.0
      assert Bidding.estimate(strong, :hearts, false, :louisiana) == 7.0

      opponent = Scenario.bidding(me: :east, bids: [north: 6], hand: close)
      partner = Scenario.bidding(me: :south, bids: [north: 6, east: :pass], hand: strong)

      for state <- [opponent, partner] do
        assert {:pass, _} = decide(%{state | variant: :louisiana})
      end
    end
  end

  describe "honours and uncovered Fives" do
    test "report pattern 1: the Ace, King and Queen of diamonds take the 6 an open auction leaves" do
      cards = [
        {12, :diamonds},
        {13, :diamonds},
        {12, :hearts},
        {11, :hearts},
        {14, :diamonds},
        {3, :clubs},
        {4, :clubs},
        {11, :clubs},
        {7, :spades}
      ]

      state = Scenario.bidding(me: :west, dealer: :east, bids: [south: :pass], hand: cards)

      assert decide(state) ==
               {{:bid, 6},
                "Diamonds are worth about 8 with the Ace, King and Queen, so I bid the 6 that takes it."}
    end

    test "report pattern 3: a Five under a King with three trumps passes an open auction" do
      cards = [
        {11, :spades},
        {6, :hearts},
        {6, :clubs},
        {7, :hearts},
        {11, :diamonds},
        {4, :diamonds},
        {5, :clubs},
        {13, :spades},
        {13, :clubs}
      ]

      state =
        Scenario.bidding(
          me: :north,
          dealer: :east,
          bids: [south: :pass, west: :pass],
          hand: cards
        )

      assert decide(state) ==
               {:pass, "My Five has no cover, so spades are worth about 3; I pass."}
    end

    test "the King and Queen count under the Ace, the Jack under two higher honours" do
      estimates = %{
        [14, 13, 12] => 8.25,
        [14, 13, 12, 11] => 9.0,
        [14, 13, 11, 4] => 8.5,
        [14, 12, 11, 4] => 7.5,
        [14, 13, 4] => 6.25,
        [14, 13] => 4.0,
        [14, 12, 4] => 3.25,
        [13, 12, 11] => 2.75
      }

      for {ranks, expected} <- estimates do
        assert Bidding.estimate(hand(suit(:hearts, ranks)), :hearts, false) == expected,
               inspect(ranks)
      end

      assert Bidding.estimate(hand(suit(:hearts, [14, 13, 12])), :hearts, false, :louisiana) ==
               8.0
    end

    test "a Five is covered by four trumps or by the Ace with three, never by the King" do
      estimates = %{
        [13, 7, 5] => 2.75,
        [14, 7, 5] => 6.25,
        [13, 8, 7, 5] => 5.5,
        [14, 5] => 1.5
      }

      for {ranks, expected} <- estimates do
        assert Bidding.estimate(hand(suit(:hearts, ranks)), :hearts, false) == expected,
               inspect(ranks)
      end

      cards = hand(suit(:hearts, [5, 4]) ++ [{5, :diamonds}])

      assert {:pass, "My Fives have no cover, so hearts are worth about 1; I pass."} =
               decide(Scenario.bidding(me: :north, hand: cards))

      weak = hand(suit(:hearts, [11, 10, 5]))

      assert {:pass, "My best suit is not enough: Hearts are worth about 1 points" <> _} =
               decide(Scenario.bidding(me: :north, hand: weak))
    end

    test "a Five without cover never brings a hand within the volunteer margin" do
      reach = 6 - Thresholds.get(:volunteer_margin)

      for size <- 1..3,
          held <- combinations(Knowledge.all_trumps(:hearts), size),
          Enum.any?(held, &match?({5, _}, &1)),
          size < 3 or {14, :hearts} not in held do
        assert Bidding.estimate(held, :hearts, true) < reach, inspect(held)
      end
    end
  end

  describe "decide_bid/2" do
    test "AE1: J, 10, 7, 6, 5 first to bid bids below 9" do
      {action, _reason} =
        decide(Scenario.bidding(me: :north, hand: hand(suit(:hearts, [11, 10, 7, 6, 5]))))

      assert action == :pass or match?({:bid, n} when n < 9, action)
    end

    test "AE2: no trump above the 9 and no Five passes" do
      cards =
        suit(:hearts, [9, 8, 4]) ++
          suit(:diamonds, [7, 6]) ++ suit(:clubs, [9, 3]) ++ suit(:spades, [8, 2])

      assert {:pass, _} = decide(Scenario.bidding(me: :north, hand: cards))
    end

    test "AE3: partner bid 8, the next seat passed, A-K-5 passes" do
      state =
        Scenario.bidding(
          me: :south,
          bids: [north: 8, east: :pass],
          hand: hand(suit(:hearts, [14, 13, 5]))
        )

      assert {:pass, reason} = decide(state)
      assert reason =~ "Partner's 8 stands"
    end

    test "AE4: a dealer with a worthless hand after three passes bids 6 and says it was forced" do
      cards =
        suit(:hearts, [9, 8]) ++
          suit(:diamonds, [7, 6, 4]) ++ suit(:clubs, [9, 3]) ++ suit(:spades, [8, 7])

      state =
        Scenario.bidding(
          me: :west,
          dealer: :west,
          bids: [north: :pass, east: :pass, south: :pass],
          hand: cards
        )

      assert {{:bid, 6}, reason} = decide(state)
      assert reason =~ "must bid"
    end

    test "both Fives of one colour bid higher than one Five with the same small trumps" do
      both = hand(suit(:hearts, [5, 7, 4]) ++ [{5, :diamonds}])
      one = hand(suit(:hearts, [5, 7, 4]))

      assert Bidding.estimate(both, :hearts, false) > Bidding.estimate(one, :hearts, false)

      assert bid_amount(decide(Scenario.bidding(me: :north, hand: both))) >
               bid_amount(decide(Scenario.bidding(me: :north, hand: one)))
    end

    test "a fractional estimate rounds down in the reason, and the bid is the minimum" do
      cards = hand(suit(:hearts, [14, 8, 5]))
      estimate = Bidding.estimate(cards, :hearts, false)
      assert estimate != trunc(estimate)

      assert {{:bid, 6}, reason} = decide(Scenario.bidding(me: :north, hand: cards))
      assert reason =~ "worth about #{trunc(estimate)},"
    end

    test "first seat and dealer both bid the lowest legal bid; the bonus moves only the estimate" do
      cards = hand(suit(:hearts, [14, 8, 5]))

      {{:bid, first}, _} = decide(Scenario.bidding(me: :north, hand: cards))

      {{:bid, dealer}, _} =
        decide(
          Scenario.bidding(
            me: :west,
            dealer: :west,
            bids: [north: :pass, east: :pass, south: 6],
            hand: cards
          )
        )

      assert {first, dealer} == {6, 7}

      assert Bidding.estimate(cards, :hearts, true) ==
               Bidding.estimate(cards, :hearts, false) + Thresholds.get(:dealer_bonus)
    end

    test "passes when an opponent has already bid above its estimate" do
      cards = hand(suit(:hearts, [14, 13, 5]))
      own = trunc(Bidding.estimate(cards, :hearts, false))

      state = Scenario.bidding(me: :south, bids: [east: own + 1], dealer: :north, hand: cards)
      assert {:pass, reason} = decide(state)
      assert reason =~ "below the #{own + 2} needed"
    end

    test "raises partner by one step, however strong the hand" do
      strong = hand(suit(:hearts, [14, 13, 12, 11, 10, 5, 2]) ++ [{5, :diamonds}])

      assert Bidding.estimate(strong, :hearts, false) >=
               7 + Thresholds.get(:overbid_partner_margin)

      state = Scenario.bidding(me: :south, bids: [north: 7, east: :pass], hand: strong)
      assert {{:bid, 8}, _} = decide(state)
    end

    test "equal estimates resolve to the same suit on every run" do
      cards =
        suit(:spades, [14, 13, 5]) ++ suit(:diamonds, [14, 13, 5]) ++ suit(:clubs, [9, 8, 3])

      results = for _ <- 1..20, do: Bidding.best_suit(cards, false)
      assert Enum.uniq(results) == [{:diamonds, Bidding.estimate(cards, :diamonds, false)}]
    end

    test "chooses a legal action when only one bid remains" do
      state = Scenario.bidding(me: :west, bids: [north: :pass, east: 12, south: 13], hand: big())

      legal = Scenario.legal(state)
      assert legal == [{:bid, 14}, :pass]
      assert Bidding.estimate(big(), :hearts, true) < 14 - Thresholds.get(:volunteer_margin)
      assert {:pass, _} = decide(state)

      strong = hand(suit(:hearts, [14, 13, 11, 10, 9, 5]))
      assert Bidding.estimate(strong, :hearts, true) == 13.25
      state = Scenario.bidding(me: :west, bids: [north: :pass, east: 12, south: 13], hand: strong)

      assert {{:bid, 14},
              "Hearts are worth about 13 with the Ace, King and Jack, close enough to take the 14."} =
               decide(state)
    end

    test "a dealer that is not forced bids one over the table, however strong" do
      strong = hand(suit(:hearts, [14, 13, 12, 11, 10, 5, 2]) ++ [{5, :diamonds}])

      state =
        Scenario.bidding(me: :west, bids: [north: :pass, east: :pass, south: 6], hand: strong)

      assert Bidding.estimate(strong, :hearts, true) >= 13
      assert {{:bid, 7}, _} = decide(state)
    end

    test "always returns a legal action in the bidding states of real games" do
      for seed <- 1..40,
          state <- GameTrace.states(seed),
          state.phase == :bidding do
        view = SeatView.for_seat(state, state.current_turn)
        legal = Scenario.legal(state)
        {action, reason} = Bidding.decide_bid(view, legal)

        assert action in legal
        assert reason != ""
      end
    end
  end

  describe "decide_trump/2" do
    test "AE19: names hearts holding A, K, 5 of hearts" do
      cards = hand(suit(:hearts, [14, 13, 5]))
      state = Scenario.declaring(me: :east, hand: cards)

      assert {{:declare_trump, :hearts}, reason} =
               Bidding.decide_trump(Scenario.view(state), Scenario.legal(state))

      assert reason =~ "Hearts"
    end

    test "names the suit the bid was based on" do
      cards =
        suit(:clubs, [14, 11, 10, 5]) ++
          [{5, :spades}] ++ suit(:hearts, [9, 8]) ++ suit(:diamonds, [7, 6])

      {suit, _} = Bidding.best_suit(cards, false)
      state = Scenario.declaring(me: :north, hand: cards)

      assert {{:declare_trump, ^suit}, _} =
               Bidding.decide_trump(Scenario.view(state), Scenario.legal(state))

      assert suit == :clubs
    end
  end

  defp combinations(_cards, 0), do: [[]]
  defp combinations([], _size), do: []

  defp combinations([card | rest], size) do
    for(held <- combinations(rest, size - 1), do: [card | held]) ++ combinations(rest, size)
  end

  defp bid_amount({{:bid, amount}, _}), do: amount
  defp bid_amount({:pass, _}), do: 0
end
