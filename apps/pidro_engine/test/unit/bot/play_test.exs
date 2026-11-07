defmodule Pidro.Bot.PlayTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Play
  alias Pidro.Core.SeatView
  alias Pidro.Test.{GameTrace, Scenario}

  doctest Pidro.Bot.Play

  # Hearts are trump; integers are hearts, :off5 is the Five of diamonds.
  defp plays(opts) do
    state = Scenario.playing(opts)
    legal = Scenario.legal(state)
    {{:play_card, card} = action, reason} = Play.decide(Scenario.view(state), legal)

    assert action in legal
    assert reason =~ ~r/^[A-Z].*\.$/
    card
  end

  describe "following" do
    test "AE5: partner led the Ace, holding 5, 9, 3 plays the 5" do
      assert plays(me: :south, hands: %{south: [5, 9, 3]}, trick: [north: 14, east: 4]) ==
               {5, :hearts}
    end

    test "AE6: Ace gone, partner winning with the King, last to act with off-5 and 4 plays the off-5" do
      card =
        plays(
          me: :west,
          hands: %{west: [:off5, 4]},
          tricks: [[north: 14, east: 3, south: 2, west: 6]],
          trick: [north: 7, east: 13, south: 8]
        )

      assert card == {5, :diamonds}
    end

    test "AE7: an opponent winning with the Ace, holding 10, 7, 3 plays the 3" do
      assert plays(me: :south, hands: %{south: [10, 7, 3]}, trick: [north: 6, east: 14]) ==
               {3, :hearts}
    end

    test "AE8: an opponent led the Ace, holding K, 8, 4 plays the 4, not the King" do
      assert plays(me: :south, hands: %{south: [13, 8, 4]}, trick: [east: 14], bid: {:east, 8}) ==
               {4, :hearts}
    end

    test "AE9: last to act, partner winning with the Queen, holding A and 6 plays the 6" do
      assert plays(
               me: :south,
               hands: %{south: [14, 6]},
               trick: [west: 9, north: 12, east: 7],
               bid: {:west, 8}
             ) ==
               {6, :hearts}
    end

    test "AE10: partner led the 3, the next opponent put on the 5, holding K and 8 plays the King" do
      assert plays(me: :south, hands: %{south: [13, 8]}, trick: [north: 3, east: 5]) ==
               {13, :hearts}
    end

    test "AE11: holding 5, 9, 7, 4, 3 with an opponent winning plays the 3" do
      assert plays(me: :south, hands: %{south: [5, 9, 7, 4, 3]}, trick: [north: 2, east: 10]) ==
               {3, :hearts}
    end

    test "AE17: an opponent winning with the Ace, holding J, 10, 2 plays the 2" do
      assert plays(me: :south, hands: %{south: [11, 10, 2]}, trick: [north: 6, east: 14]) ==
               {2, :hearts}
    end

    test "AE18: the opponents' 10 is winning and the bot is last with K and 4: plays the King" do
      card =
        plays(
          me: :west,
          hands: %{west: [13, 4]},
          trick: [north: 10, east: 3, south: 7]
        )

      assert card == {13, :hearts}
    end

    test "a safe trick for partner gets the off-5 before the 5" do
      assert plays(me: :south, hands: %{south: [5, :off5, 9]}, trick: [north: 14, east: 4]) ==
               {5, :diamonds}
    end

    test "partner's Queen with points on the trick and an opponent to act: the Ace covers it" do
      assert plays(me: :south, hands: %{south: [14, 6]}, trick: [north: 12, east: 10]) ==
               {14, :hearts}
    end

    test "partner's Queen with no points on the trick and an opponent to act: plays the 6" do
      assert plays(me: :south, hands: %{south: [14, 6]}, trick: [north: 12, east: 9]) ==
               {6, :hearts}
    end

    test "an opponent's Five under partner's safe Ace does not spend the bot's highest trump" do
      card =
        plays(
          me: :west,
          hands: %{west: [13, 4]},
          trick: [north: 5, east: 14, south: 3],
          bid: {:north, 8}
        )

      assert card == {4, :hearts}
    end

    test "a single Five with the opponents winning is played" do
      assert plays(me: :south, hands: %{south: [5]}, trick: [north: 3, east: 14]) == {5, :hearts}
    end

    test "a cold seat makes the bot in third position last to act" do
      card =
        plays(
          me: :south,
          hands: %{south: [14, 5, 6]},
          trick: [north: 12, east: 7],
          cold: [:west]
        )

      assert card == {5, :hearts}
    end

    test "never plays non-trump filler" do
      assert plays(
               me: :south,
               hands: %{south: [9, 3, {14, :clubs}, {13, :spades}]},
               trick: [north: 2, east: 10]
             ) == {3, :hearts}
    end

    test "never gives the opponents a Five while holding another card" do
      assert plays(me: :south, hands: %{south: [5, :off5, 14]}, trick: [north: 3, east: 13]) ==
               {14, :hearts}
    end
  end

  describe "leading" do
    test "AE11: does not lead the 5 from 5, 9, 7, 4, 3" do
      assert plays(me: :north, hands: %{north: [5, 9, 7, 4, 3]}) == {3, :hearts}
    end

    test "AE12: the bid winner holding A, 8, 3 does not open with the Ace" do
      assert plays(me: :north, hands: %{north: [14, 8, 3]}) == {3, :hearts}
    end

    test "AE13: the bid winner holding A, K, Q, J, 5, 2 opens with the Ace" do
      assert plays(me: :north, hands: %{north: [14, 13, 12, 11, 5, 2]}) == {14, :hearts}
    end

    test "from four trumps without the King and Queen leads low and keeps the Ace" do
      assert plays(me: :north, hands: %{north: [14, 9, 8, 3]}) == {3, :hearts}
    end

    test "report pattern 13: the bidder with A, 5, off-5, 2, 7 of diamonds leads the 2" do
      state =
        Scenario.playing(
          me: :south,
          trump: :diamonds,
          bid: {:south, 7},
          dealer: :south,
          hands: %{south: [14, 5, :off5, 2, 7, {13, :spades}]}
        )

      assert Play.decide(Scenario.view(state), Scenario.legal(state)) ==
               {{:play_card, {2, :diamonds}},
                "I lead my 2 of Diamonds to draw trumps and keep the Ace for a Five."}
    end

    test "report pattern 14: the bidder with 7, A, 2, K of clubs leads the 2" do
      hand = [7, 14, 2, 13, {13, :hearts}, {11, :diamonds}]

      assert plays(
               me: :east,
               trump: :clubs,
               bid: {:east, 6},
               dealer: :north,
               hands: %{east: hand}
             ) ==
               {2, :clubs}
    end

    test "keeping the Ace, leads the 2 before the 3 and otherwise the lowest non-point trump" do
      assert plays(me: :north, hands: %{north: [14, 9, 3, 2]}) == {2, :hearts}
      assert plays(me: :north, hands: %{north: [14, 13, 11, 8]}) == {8, :hearts}
    end

    test "with no low trump to lead, opens with the Ace from four trumps" do
      assert plays(me: :north, hands: %{north: [14, 11, 10, 5]}) == {14, :hearts}
    end

    test "keeps the Ace only on the opening lead from four trumps" do
      assert plays(me: :north, hands: %{north: [14, 9, 2]}) == {9, :hearts}

      later = [[north: 7, east: 4, south: 6, west: 3]]
      assert plays(me: :north, hands: %{north: [14, 9, 8, 2]}, tricks: later) == {14, :hearts}
    end

    test "with only the two Fives leads the off-5" do
      assert plays(me: :north, hands: %{north: [5, :off5]}) == {5, :diamonds}
    end

    test "with the two Fives and non-trump filler leads the off-5" do
      hand = [5, :off5, {14, :clubs}, {13, :clubs}, {12, :spades}, {11, :spades}]
      assert plays(me: :north, hands: %{north: hand}) == {5, :diamonds}
    end

    test "a later lead for the bidding side with the Ace and King gone leads the Queen" do
      card =
        plays(
          me: :north,
          hands: %{north: [12, 8, 6]},
          tricks: [[north: 14, east: 13, south: 3, west: 4]]
        )

      assert card == {12, :hearts}
    end

    test "the defending side leads its lowest non-point trump" do
      card =
        plays(
          me: :east,
          hands: %{east: [9, 6, 3]},
          tricks: [[north: 7, east: 14, south: 4, west: 2]]
        )

      assert card == {3, :hearts}
    end

    test "leads the 2 before a point card when nothing else is left" do
      assert plays(me: :east, hands: %{east: [10, 2, 5]}, bid: {:east, 8}) == {2, :hearts}
    end
  end

  describe "every decision in real games" do
    test "is a legal card with a one-sentence reason" do
      for seed <- 1..40,
          state <- GameTrace.states(seed),
          state.phase == :playing,
          state.current_turn do
        legal = Scenario.legal(state)
        {action, reason} = Play.decide(SeatView.for_seat(state, state.current_turn), legal)

        assert action in legal
        assert reason =~ ~r/^[^.]+\.$/, reason
      end
    end
  end
end
