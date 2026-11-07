defmodule Pidro.Game.PlaySettledTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.Card
  alias Pidro.Game.{Engine, Play}
  alias Pidro.Test.Scenario

  @positions [:north, :east, :south, :west]
  @first_trick [[north: 13, east: 14, south: 8, west: 11]]

  defp lone_holder(holder, hand) do
    Scenario.playing(
      me: holder,
      hands: %{holder => hand},
      cold: List.delete(@positions, holder),
      tricks: @first_trick
    )
  end

  describe "settled_play/1" do
    test "a lone holder leading plays their highest trump, whichever seat holds them" do
      for holder <- [:south, :east] do
        assert Play.settled_play(lone_holder(holder, [2, 12, :off5])) ==
                 {holder, {12, :hearts}}
      end
    end

    test "is not settled while two players still hold trumps" do
      state =
        Scenario.playing(
          me: :south,
          hands: %{south: [14, 2], west: [10]},
          cold: [:north, :east],
          tricks: @first_trick
        )

      assert Play.settled_play(state) == nil
    end

    test "is not settled inside a trick led by a player who then went cold" do
      state =
        Scenario.playing(
          me: :north,
          hands: %{north: [14, 2]},
          cold: [:east, :south, :west],
          trick: [west: 9]
        )

      assert Play.settled_play(state) == nil
    end

    test "Louisiana never settles, as its players never go cold" do
      assert Play.settled_play(louisiana()) == nil
    end

    test "playing out the sweep scores the same as any other order" do
      state = lone_holder(:south, [2, 3, 10, :off5, 5])

      swept = play_out(state, fn s -> elem(Play.settled_play(s), 1) end)

      lowest_first =
        play_out(state, fn s ->
          s
          |> Play.legal_plays(:south)
          |> Enum.min_by(& &1, &(Card.compare(&1, &2, :hearts) != :gt))
        end)

      assert swept.hand_number == state.hand_number + 1
      assert swept.cumulative_scores == lowest_first.cumulative_scores
      assert swept.cumulative_scores == %{north_south: 12, east_west: 2}
    end
  end

  describe "Engine.settle_hand/1" do
    test "lays the holder's trumps down in one step, as if each were tapped highest first" do
      cases = [
        {:south, [14], [{14, :hearts}]},
        {:east, [2, 3, 10, :off5, 5, {9, :clubs}],
         [{10, :hearts}, {5, :hearts}, {5, :diamonds}, {3, :hearts}, {2, :hearts}]}
      ]

      for {holder, hand, laid} <- cases do
        state = lone_holder(holder, hand)
        swept = play_out(state, fn s -> elem(Play.settled_play(s), 1) end)

        assert {:ok, settled} = Engine.settle_hand(state)

        assert Enum.drop(settled.events, length(state.events)) ==
                 [{:hand_settled, holder, laid} | Enum.drop(swept.events, length(state.events))]

        assert settled.last_hand ==
                 Map.put(swept.last_hand, :settled, %{position: holder, cards: laid})

        assert Map.drop(settled, [:events, :last_hand]) == Map.drop(swept, [:events, :last_hand])
        assert settled.hand_number == state.hand_number + 1

        assert Enum.map(settled.last_hand.tricks, &length(&1.plays)) == [
                 4 | Enum.map(laid, fn _ -> 1 end)
               ]
      end
    end

    test "the Fives and the Two score for the holder's team" do
      {:ok, settled} = Engine.settle_hand(lone_holder(:east, [2, 3, 10, :off5, 5]))

      # The first trick (A, K, J, 8) is east's: 2 points, then 1 + 5 + 5 + 1.
      assert settled.last_hand.captured == %{north_south: 0, east_west: 14}
    end

    test "at own pace the hand stops on its result, settled" do
      state = lone_holder(:south, [14, 2])
      state = %{state | config: Map.put(state.config, :pace, :own)}

      {:ok, settled} = Engine.settle_hand(state)

      assert settled.phase == :hand_complete

      assert settled.last_hand.settled == %{
               position: :south,
               cards: [{14, :hearts}, {2, :hearts}]
             }
    end

    test "a hand played out to the end is not settled" do
      state = lone_holder(:south, [14])
      {:ok, played} = Engine.apply_action(state, :south, {:play_card, {14, :hearts}})

      assert Map.get(played.last_hand, :settled) == nil
    end

    test "leaves a hand that is not settled alone" do
      two_holders =
        Scenario.playing(
          me: :south,
          hands: %{south: [14, 2], west: [10]},
          cold: [:north, :east],
          tricks: @first_trick
        )

      led_by_cold =
        Scenario.playing(
          me: :north,
          hands: %{north: [14, 2]},
          cold: [:east, :south, :west],
          trick: [west: 9]
        )

      for state <- [two_holders, led_by_cold, louisiana()] do
        assert Engine.settle_hand(state) == {:error, :not_settled}
      end
    end

    test "is the holder's claim on the remaining tricks, and nobody else's" do
      state = lone_holder(:south, [14, 2])

      assert Engine.apply_action(state, :south, :claim_remaining) == Engine.settle_hand(state)
      assert {:error, _} = Engine.apply_action(state, :west, :claim_remaining)

      two_holders =
        Scenario.playing(
          me: :south,
          hands: %{south: [14, 2], west: [10]},
          cold: [:north, :east],
          tricks: @first_trick
        )

      assert Engine.apply_action(two_holders, :south, :claim_remaining) ==
               {:error, :not_settled}
    end
  end

  defp louisiana do
    state =
      Scenario.playing(
        me: :north,
        hands: %{
          north: [14, 2],
          south: [{9, :clubs}, {8, :clubs}],
          east: [{9, :spades}, {8, :spades}],
          west: [{10, :clubs}, {7, :clubs}]
        }
      )

    %{state | variant: :louisiana}
  end

  defp play_out(%{phase: :playing} = state, pick) do
    {:ok, state} = Engine.apply_action(state, state.current_turn, {:play_card, pick.(state)})
    play_out(state, pick)
  end

  defp play_out(state, _pick), do: state
end
