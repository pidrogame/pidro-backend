defmodule Pidro.Bot.Search.DeterminizerTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Search.Determinizer
  alias Pidro.Core.{Card, Deck, SeatView}
  alias Pidro.Game.{DealerRob, Engine}
  alias Pidro.Test.GameTrace

  # Every decision a seat faced in some seeded random games, auto and manual rob.
  defp views(phase, seeds) do
    for seed <- seeds,
        state <- GameTrace.states(seed, auto_dealer_rob: rem(seed, 2) == 0),
        state.phase == phase,
        state.current_turn != nil,
        Engine.legal_actions(state, state.current_turn) != [],
        do: SeatView.for_seat(state, state.current_turn)
  end

  defp worlds(view, seed, count) do
    {worlds, _rng} =
      Enum.map_reduce(1..count, Determinizer.rng(seed), fn _, rng ->
        {:ok, world, rng} = Determinizer.sample(view, rng)
        {world, rng}
      end)

    worlds
  end

  defp played_by(view, pos) do
    for trick <- view.tricks ++ List.wrap(view.current_trick), {^pos, c} <- trick.plays, do: c
  end

  defp trumps(cards, trump), do: Enum.filter(cards, &Card.is_trump?(&1, trump))
  defp non_trumps(cards, trump), do: Enum.reject(cards, &Card.is_trump?(&1, trump))

  describe "in play" do
    setup do
      {:ok, views: views(:playing, 1..12)}
    end

    test "every real position has a consistent world", %{views: views} do
      assert length(views) > 500

      for view <- views do
        assert {:ok, _world, _rng} = Determinizer.sample(view, Determinizer.rng(1)),
               inspect(view, limit: :infinity)
      end
    end

    test "worlds respect every public fact", %{views: views} do
      for view <- Enum.take_every(views, 5), world <- worlds(view, 3, 4) do
        me = view.position
        trump = view.trump_suit
        others = [:north, :east, :south, :west] -- [me]

        # Hand counts, and the hands go to the other seats only.
        assert Map.keys(world.hands) |> Enum.sort() == Enum.sort(others)

        for pos <- others do
          assert length(world.hands[pos]) == view.players[pos].hand_count
          assert length(Map.get(world.folded, pos, [])) == view.players[pos].folded_count
        end

        # The unseen cards are dealt exactly once each, and only they are.
        dealt =
          Enum.concat([
            Enum.concat(Map.values(world.hands)),
            Enum.concat(Map.values(world.folded)),
            world.discards,
            world.deck
          ])

        assert Enum.sort(dealt) == Enum.sort(Determinizer.unseen(view))

        known =
          view.hand ++
            Enum.flat_map(view.tricks ++ List.wrap(view.current_trick), fn t ->
              Enum.map(t.plays, &elem(&1, 1))
            end) ++
            Enum.concat(Map.values(view.killed_cards)) ++ view.players[me].revealed_cards

        assert Enum.sort(dealt ++ known) == Enum.sort(Deck.ordered())

        # Cold seats hold no trump; folded faces are never trumps.
        for pos <- others, view.players[pos].eliminated? do
          assert world.hands[pos] == []
          assert trumps(Map.get(world.folded, pos, []), trump) == []
        end

        # A non-dealer drew `cards_requested` cards: no more non-trumps than that.
        for pos <- others, pos != view.current_dealer do
          held = world.hands[pos] ++ Map.get(world.folded, pos, [])
          assert length(non_trumps(held, trump)) <= Map.fetch!(view.cards_requested, pos)
        end

        # The first deal's discards hold no trump: an unseen trump outside a
        # hand was robbed away by the dealer or is still in an undealt pack.
        for card <- trumps(world.discards, trump) do
          robbed? = world.dealer_pool != nil and card in world.dealer_pool
          own? = view.current_dealer == me
          assert robbed? or own?
        end
      end
    end

    test "the dealer's hand is the rob selection from its sampled pool", %{views: views} do
      robbed =
        for view <- views,
            view.current_dealer != view.position,
            world <- worlds(view, 5, 3),
            world.dealer_pool != nil,
            do: {view, world}

      assert length(robbed) > 100

      for {view, world} <- robbed do
        dealer = view.current_dealer

        start =
          played_by(view, dealer) ++ world.hands[dealer] ++ Map.get(world.folded, dealer, [])

        assert Enum.sort(DealerRob.select_best_cards(world.dealer_pool, view.trump_suit)) ==
                 Enum.sort(start)

        # The pool's non-trumps come only from the leftover pack.
        drawn = view.cards_requested |> Map.values() |> Enum.sum()
        assert length(non_trumps(world.dealer_pool, view.trump_suit)) <= 16 - drawn
      end
    end

    test "sampling reproduces from a seed and varies across seeds", %{views: views} do
      view = Enum.find(views, &(&1.trick_number == 1 and length(Determinizer.unseen(&1)) > 30))

      assert worlds(view, 11, 5) == worlds(view, 11, 5)
      assert worlds(view, 11, 5) != worlds(view, 12, 5)
    end
  end

  # In these games bids, trump and plays are random, so at the opening lead
  # the true hands are a uniform draw from the deals the view allows. A
  # sampler that is uniform over those deals predicts each seat's trump
  # count without bias. Weighting every hand set alike, ignoring that a
  # non-dealer's trumps are its kept ones plus its draws, under-predicts
  # non-dealers by 0.12 trumps.
  test "at the opening lead, worlds give non-dealers as many trumps as real deals do" do
    pairs =
      for seed <- 1..150,
          state <- GameTrace.states(seed),
          state.phase == :playing and state.tricks == [] and state.current_trick == nil,
          view = SeatView.for_seat(state, state.current_turn),
          worlds = worlds(view, 13, 40),
          pos <- [:north, :east, :south, :west] -- [view.position, view.current_dealer] do
        predicted = Enum.sum_by(worlds, &length(trumps(&1.hands[pos], view.trump_suit))) / 40
        {predicted, length(trumps(state.players[pos].hand, view.trump_suit))}
      end

    assert length(pairs) > 1_000
    predicted = Enum.sum_by(pairs, &elem(&1, 0)) / length(pairs)
    actual = Enum.sum_by(pairs, &elem(&1, 1)) / length(pairs)
    assert abs(predicted - actual) < 0.04, "predicted #{predicted}, actual #{actual}"
  end

  describe "in the auction" do
    test "the other seats get nine unseen cards each and the pack the rest" do
      for view <- Enum.take(views(:bidding, 1..3), 20), world <- worlds(view, 2, 3) do
        others = [:north, :east, :south, :west] -- [view.position]

        assert Enum.all?(others, &(length(world.hands[&1]) == 9))
        assert length(world.deck) == 16

        dealt = Enum.concat(Map.values(world.hands)) ++ world.deck
        assert Enum.sort(dealt ++ view.hand) == Enum.sort(Deck.ordered())
      end
    end
  end
end
