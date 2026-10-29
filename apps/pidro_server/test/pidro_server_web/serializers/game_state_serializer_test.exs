defmodule PidroServerWeb.Serializers.GameStateSerializerTest do
  @moduledoc """
  The serializer is an allow-list, so a field added to `%GameState{}` stays out
  of client payloads until somebody adds it here on purpose. The game's chance
  stream is the field where that matters most: the rest of the deck follows
  from it, so a client that saw it could read the hands it has not been dealt
  yet.

  These tests assert the containment rather than assuming it.
  """

  use ExUnit.Case, async: true

  alias Pidro.Core.GameState
  alias Pidro.Game.{Dealing, Engine}
  alias PidroServerWeb.Serializers.GameStateSerializer

  # A state with cuts drawn, a shuffled deck and dealt hands — everything the
  # chance stream has produced so far.
  defp dealt_state do
    {:ok, cut} = Dealing.select_dealer(GameState.new(seed: 1))
    {:ok, dealt} = Engine.advance_from_dealer_selection(cut)

    dealt
  end

  # `term_to_binary/1` prefixes a version byte that never recurs inside a term,
  # so it has to come off before the encoding can be used as a needle.
  defp encoded_chance(chance) do
    encoded = :erlang.term_to_binary(chance)
    binary_part(encoded, 1, byte_size(encoded) - 1)
  end

  # The dealer-cut cards are public and go back into the pack, so they can
  # legitimately match a card dealt later.
  defp refute_cards(payload, cards) do
    json = payload |> Map.delete(:dealer_selection_cuts) |> Jason.encode!()

    for {rank, suit} <- cards do
      refute json =~ Jason.encode!(%{rank: rank, suit: suit})
    end
  end

  describe "serialize/2" do
    test "trick signals are additive and finished points exclude the trump two" do
      for variant <- [:finnish, :louisiana] do
        trick = %Pidro.Core.Types.Trick{
          number: 1,
          leader: :north,
          plays: [{:north, {5, :diamonds}}, {:east, {2, :hearts}}, {:south, {10, :hearts}}]
        }

        state = %{dealt_state() | variant: variant, trump_suit: :hearts, current_trick: trick}
        payload = GameStateSerializer.serialize(state)
        plays = GameStateSerializer.serialize_plays(trick.plays)

        assert payload.current_trick == plays
        assert payload.current_trick_details.plays == plays
        assert payload.current_trick_details.cards == plays
        assert payload.current_trick_details.winner == nil

        assert payload.current_trick_details.winning ==
                 %{position: :south, card: %{rank: 10, suit: :hearts}}

        assert payload.current_trick_details.points == 6
        assert payload.current_trick_details.two_of_trump == %{position: :east, points: 1}
        assert payload.scores == payload.cumulative_scores
        assert payload.hand_points == state.hand_points

        {:ok, finished} = Pidro.Game.Play.complete_trick(state)
        [completed] = GameStateSerializer.serialize(finished).tricks
        assert completed.winner == :south
        assert completed.points == 6
        assert completed.two_of_trump == %{position: :east, points: 1}
        assert completed.plays == plays
        assert completed.cards == plays
      end
    end

    test "the last hand's bids, trump and tricks have the live fields' shapes" do
      finished =
        1
        |> Pidro.Test.DeterministicGame.opening()
        |> Pidro.Test.DeterministicGame.play_until(&(&1.hand_number == 2))

      last_hand = finished.last_hand
      assert [_ | _] = last_hand.tricks
      assert [_ | _] = last_hand.bids
      assert finished.tricks == [] and finished.bids == [] and finished.trump_suit == nil

      payload = GameStateSerializer.serialize(finished)

      # The same hand as it would have been serialized live, before the reset.
      live =
        GameStateSerializer.serialize(%{
          finished
          | tricks: last_hand.tricks,
            bids: last_hand.bids,
            trump_suit: last_hand.trump
        })

      assert payload.last_hand.tricks == live.tricks
      assert payload.last_hand.bids == live.bids
      assert payload.last_hand.trump == live.trump_suit
      assert payload.last_hand.trump in [:hearts, :diamonds, :clubs, :spades]

      assert Map.drop(payload.last_hand, [:bids, :trump, :tricks, :point_cards]) ==
               Map.drop(last_hand, [:bids, :trump, :tricks, :point_cards])

      assert payload.last_hand.point_cards ==
               Enum.map(last_hand.point_cards, fn %{card: {rank, suit}} = point_card ->
                 %{point_card | card: %{rank: rank, suit: suit}}
               end)

      assert payload.hand_history == [Map.drop(payload.last_hand, [:bids, :tricks])]

      wire = payload |> Jason.encode!() |> Jason.decode!()
      live_wire = live |> Jason.encode!() |> Jason.decode!()
      assert wire["last_hand"]["tricks"] == live_wire["tricks"]
      assert wire["last_hand"]["bids"] == live_wire["bids"]
      assert wire["last_hand"]["trump"] == live_wire["trump_suit"]
    end

    test "folded faces stay with their owner, including after scoring and in history" do
      state =
        Pidro.Test.Scenario.playing(
          me: :north,
          hands: %{north: [14, 2], east: [{10, :clubs}, {9, :spades}]}
        )

      assert GameStateSerializer.serialize_public(state).players.east.folded_count == 0
      {:ok, cold} = Engine.apply_action(state, :north, {:play_card, {14, :hearts}})
      assert cold.players.east.eliminated?
      assert cold.current_turn == :south
      assert {:player_went_cold, :east, [{10, :clubs}, {9, :spades}]} in cold.events

      for viewer <- [nil, :north, :east, :south, :west] do
        payload = GameStateSerializer.serialize(cold, viewer)
        assert payload.players.east.eliminated
        assert payload.players.east.folded_count == 2

        assert payload.players.east.revealed_cards ==
                 if(viewer == :east,
                   do: [%{rank: 10, suit: :clubs}, %{rank: 9, suit: :spades}],
                   else: []
                 )

        # The raw hand log remains authoritative, never part of a client payload.
        refute Map.has_key?(payload, :events)

        if viewer != :east do
          for card <- [%{rank: 10, suit: :clubs}, %{rank: 9, suit: :spades}] do
            refute Jason.encode!(payload) =~ Jason.encode!(card)
          end
        end
      end

      finished = Pidro.Test.DeterministicGame.play_until(cold, &(&1.hand_number == 2))
      assert finished.last_hand != nil
      assert length(finished.hand_history) == 1

      for viewer <- [nil, :north, :east, :south, :west] do
        payload = GameStateSerializer.serialize(finished, viewer)
        assert payload.players.east.folded_count == 0

        for card <- [%{rank: 10, suit: :clubs}, %{rank: 9, suit: :spades}] do
          refute Jason.encode!(payload.last_hand) =~ Jason.encode!(card)
          refute Jason.encode!(payload.hand_history) =~ Jason.encode!(card)
        end
      end
    end

    test "every viewer sees what each player dealt to kept and drew in the second deal" do
      state = dealt_state()
      dealer = state.current_dealer
      [first | _] = others = Enum.reject([:north, :east, :south, :west], &(&1 == dealer))

      # Each non-dealer throws all but two; the first throws seven and draws four.
      throws =
        for pos <- [dealer | others] do
          {:cards_discarded, pos, Enum.take(state.players[pos].hand, 7)}
        end

      state = %{
        state
        | phase: :playing,
          events: state.events ++ throws,
          cards_requested: Map.new(others, &{&1, 4})
      }

      for viewer <- [nil, first, dealer] do
        players = GameStateSerializer.serialize(state, viewer).players
        assert players[first].kept_count == 2
        assert players[first].discarded_count == 7
        assert players[first].drawn_count == 4
        # The dealer's discard is the dealer's edge: never counted.
        assert players[dealer].kept_count == nil
        assert players[dealer].drawn_count == nil
      end
    end

    test "a dealer picking from the pack holds their pool to themselves" do
      state = %{dealt_state() | phase: :second_deal}
      dealer = state.current_dealer
      other = Enum.find([:north, :east, :south, :west], &(&1 != dealer))

      assert GameStateSerializer.serialize(state, other).players[dealer].card_count == nil
      assert GameStateSerializer.serialize(state).players[dealer].card_count == nil
      assert GameStateSerializer.serialize(state, dealer).players[dealer].card_count == 9

      playing = %{state | phase: :playing}
      assert GameStateSerializer.serialize(playing, other).players[dealer].card_count == 9
    end

    test "no second-deal counts before the discard" do
      players = GameStateSerializer.serialize(dealt_state()).players

      assert Enum.all?(players, fn {_pos, p} ->
               p.kept_count == nil and p.discarded_count == nil and p.drawn_count == nil
             end)
    end

    test "the dealer's throw is counted once they are down to six, never shown" do
      # Seed 5 gives the dealer a pool of ten to pick six from.
      opening = Pidro.Test.DeterministicGame.opening(5)
      opening = put_in(opening.config[:auto_dealer_rob], false)

      picking =
        Pidro.Test.DeterministicGame.play_until(opening, &(&1.phase == :second_deal))

      dealer = picking.current_dealer
      pool = picking.players[dealer].hand ++ picking.deck
      assert length(pool) == 10
      others = Enum.reject([:north, :east, :south, :west], &(&1 == dealer))
      thrown = picking.discarded_cards

      for viewer <- [nil, :north, :east, :south, :west] do
        payload = GameStateSerializer.serialize(picking, viewer)
        assert payload.players[dealer].discarded_count == nil

        for pos <- others do
          assert payload.players[pos].discarded_count ==
                   9 - payload.players[pos].kept_count
        end

        assert payload.killed_cards == %{}
        refute_cards(payload, thrown ++ picking.deck)
      end

      played = Pidro.Test.DeterministicGame.step(picking)
      assert played.phase == :playing
      dealer_thrown = pool -- played.players[dealer].hand
      assert length(dealer_thrown) == 4

      for viewer <- [nil, :north, :east, :south, :west] do
        payload = GameStateSerializer.serialize(played, viewer)
        assert payload.players[dealer].discarded_count == 4
        assert payload.players[dealer].kept_count == nil
        refute_cards(payload, thrown ++ dealer_thrown)
      end

      # A dealer already holding six trumps, or facing an empty pack, takes
      # nothing up and throws nothing.
      unrobbed = %{played | dealer_pool_size: nil}
      assert GameStateSerializer.serialize(unrobbed).players[dealer].discarded_count == 0

      scored = %{played | phase: :hand_complete}
      assert GameStateSerializer.serialize(scored).players[dealer].discarded_count == nil
    end

    test "killed trumps are face up for every viewer until the hand ends" do
      state = Pidro.Test.Scenario.playing(me: :north, killed: %{east: [7, 8]})

      for viewer <- [nil, :north, :east, :south, :west] do
        assert GameStateSerializer.serialize(state, viewer).killed_cards == %{
                 east: [%{rank: 7, suit: :hearts}, %{rank: 8, suit: :hearts}]
               }
      end

      # An own-pace room holds the scored hand on the table before the next deal.
      own = put_in(state.config[:pace], :own)
      scored = Pidro.Test.DeterministicGame.play_until(own, &(&1.phase != :playing))
      assert scored.phase == :hand_complete
      next = Pidro.Test.DeterministicGame.play_until(state, &(&1.hand_number == 2))

      for finished <- [scored, next], viewer <- [nil, :north, :east, :south, :west] do
        assert GameStateSerializer.serialize(finished, viewer).killed_cards == %{}
      end
    end

    test "absent and empty current tricks retain their existing shapes" do
      state = dealt_state()
      payload = GameStateSerializer.serialize(state)
      assert payload.current_trick == []
      assert payload.current_trick_details == nil
      assert payload.last_hand == nil
      assert payload.hand_history == []

      empty = %Pidro.Core.Types.Trick{number: 1, leader: :north}

      payload =
        GameStateSerializer.serialize(%{state | current_trick: empty, trump_suit: :hearts})

      assert payload.current_trick == []
      assert payload.current_trick_details.winning == nil
      assert payload.current_trick_details.points == 0
      assert payload.current_trick_details.two_of_trump == nil
    end

    test "the payload has no :chance key" do
      state = dealt_state()

      assert state.chance != nil
      refute Map.has_key?(GameStateSerializer.serialize(state), :chance)
      refute Map.has_key?(GameStateSerializer.serialize(state, :north), :chance)
      refute Map.has_key?(GameStateSerializer.serialize_public(state), :chance)
    end

    test "the payload mentions nothing of the chance stream" do
      state = dealt_state()
      payload = GameStateSerializer.serialize(state, :north)

      # The algorithm tag would be the giveaway if the value leaked whole or in
      # part, under this name or any other.
      refute payload |> inspect(limit: :infinity) |> String.contains?("exsss")

      assert :binary.match(:erlang.term_to_binary(payload), encoded_chance(state.chance)) ==
               :nomatch

      # Control: the same search finds the stream in the state itself, so the
      # assertion above is testing something.
      assert :binary.match(:erlang.term_to_binary(state), encoded_chance(state.chance)) !=
               :nomatch
    end

    test "serializing a state whose chance differs produces the same payload" do
      state = dealt_state()
      restreamed = %{state | chance: GameState.new(seed: 99).chance}

      assert GameStateSerializer.serialize(state, :north) ==
               GameStateSerializer.serialize(restreamed, :north)
    end
  end
end
