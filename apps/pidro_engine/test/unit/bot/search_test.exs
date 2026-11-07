defmodule Pidro.Bot.SearchTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.{Rulebook, Search}
  alias Pidro.Test.Scenario

  @six {:play_card, {6, :hearts}}
  @ace {:play_card, {14, :hearts}}

  describe "pick/3, the readability veto" do
    test "the rulebook's move stands inside the margin" do
      assert {@six, "Rulebook says 6♥; search prefers A♥ by only 0.3 points, so 6♥."} =
               Search.pick(%{@six => 1.0, @ace => 1.3}, @six, 0.4)
    end

    test "search overrules the rulebook outside the margin" do
      assert {@ace, "Rulebook says 6♥; search prefers A♥ by 0.9 points, so A♥."} =
               Search.pick(%{@six => 1.0, @ace => 1.9}, @six, 0.4)
    end

    test "without the veto any gain overrules, and agreement keeps the rulebook" do
      assert {@ace, _} = Search.pick(%{@six => 1.0, @ace => 1.3}, @six, 0)

      assert {@six, "Rulebook says 6♥; search agrees."} =
               Search.pick(%{@six => 2.0, @ace => 1.3}, @six, 0)

      assert {@six, _} = Search.pick(%{@six => 1.0, @ace => 1.0}, @six, 0)
    end
  end

  describe "play" do
    # Partner's King leads this trick and West, still to play, could hold the
    # unseen Ace as far as the rulebook can tell, so it plays low. Counting
    # says otherwise: East drew one card, so East's three cards hold at least
    # two trumps, and only the Ace and the 9 are unseen. West holds no trump,
    # the trick is safe, and the Five belongs on it now; kept back, it is
    # South's last trump and falls to East's lead on the next trick.
    defp safe_five do
      state =
        Scenario.playing(
          me: :south,
          dealer: :south,
          bid: {:north, 8},
          hands: %{
            south: [5, 6, {2, :clubs}, {3, :clubs}],
            north: [{4, :clubs}, {6, :clubs}, {7, :clubs}],
            east: [14, 9, {8, :clubs}],
            west: [{9, :clubs}, {10, :clubs}, {11, :clubs}, {12, :clubs}]
          },
          tricks: [
            [north: 12, east: 8, south: 2, west: 3],
            [north: 11, east: 7, south: 10, west: :off5]
          ],
          trick: [north: 13, east: 4]
        )

      %{state | cards_requested: %{north: 3, east: 1, west: 4}}
    end

    test "feeds a Five that only counting shows is safe" do
      state = safe_five()
      view = Scenario.view(state)
      legal = Scenario.legal(state)

      assert {{:play_card, {6, :hearts}}, _} = Rulebook.decide(view, legal)

      assert {{:play_card, {5, :hearts}}, reason} =
               Search.decide(view, legal, worlds: 20, seed: 1)

      assert reason =~ ~r/^Rulebook says 6♥; search prefers 5♥ by \d+\.\d points, so 5♥\.$/
    end

    test "decides the same move from the same seed" do
      state = safe_five()
      view = Scenario.view(state)
      legal = Scenario.legal(state)

      assert Search.analyse(view, legal, worlds: 10, seed: 4) ==
               Search.analyse(view, legal, worlds: 10, seed: 4)
    end

    test "states that differ only in the other seats' hidden cards give the same analysis" do
      one = safe_five()

      hidden = %{
        north: [{8, :clubs}, {12, :clubs}, {7, :clubs}],
        east: [{9, :hearts}, {14, :hearts}, {4, :clubs}],
        west: [{11, :clubs}, {10, :clubs}, {6, :clubs}, {9, :clubs}]
      }

      two = %{
        one
        | players:
            Map.new(one.players, fn {pos, p} -> {pos, %{p | hand: hidden[pos] || p.hand}} end),
          deck: [{2, :spades}],
          discarded_cards: [{3, :spades}]
      }

      assert one.players.east.hand != two.players.east.hand
      assert Scenario.view(one) == Scenario.view(two)

      assert Search.analyse(Scenario.view(one), Scenario.legal(one), worlds: 10, seed: 2) ==
               Search.analyse(Scenario.view(two), Scenario.legal(two), worlds: 10, seed: 2)
    end
  end

  describe "bidding" do
    @junk [{2, :hearts}, {3, :diamonds}, {4, :clubs}, {7, :spades}, {8, :hearts}] ++
            [{9, :diamonds}, {3, :clubs}, {4, :spades}, {6, :diamonds}]

    test "a dealer forced to bid keeps the rulebook's minimum" do
      state =
        Scenario.bidding(
          me: :north,
          dealer: :north,
          hand: @junk,
          bids: [east: :pass, south: :pass, west: :pass]
        )

      assert {{:bid, 6}, _} =
               Search.decide(Scenario.view(state), Scenario.legal(state), worlds: 4)
    end

    test "a partner's standing bid keeps the rulebook's partner rule" do
      state =
        Scenario.bidding(
          me: :north,
          dealer: :north,
          hand: @junk,
          bids: [east: :pass, south: 8, west: :pass]
        )

      view = Scenario.view(state)
      legal = Scenario.legal(state)
      assert Search.decide(view, legal, worlds: 4) == Rulebook.decide(view, legal)
    end

    test "takes the contract when the hand makes it, passes when it does not" do
      strong =
        Scenario.suit(:hearts, [14, 13, 12, 11, 10, 5]) ++
          [{5, :diamonds}, {2, :hearts}, {3, :clubs}]

      state = Scenario.bidding(me: :east, dealer: :north, hand: strong)

      assert {{:bid, _}, reason} =
               Search.decide(Scenario.view(state), Scenario.legal(state), worlds: 30)

      assert reason =~ "of worlds"

      state = Scenario.bidding(me: :east, dealer: :north, hand: @junk)
      assert {:pass, _} = Search.decide(Scenario.view(state), Scenario.legal(state), worlds: 30)
    end
  end
end
