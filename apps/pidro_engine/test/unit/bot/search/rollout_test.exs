defmodule Pidro.Bot.Search.RolloutTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Search.{Determinizer, Rollout}
  alias Pidro.Core.SeatView
  alias Pidro.Game.Engine
  alias Pidro.Test.GameTrace

  defp positions(phase) do
    for seed <- 21..26,
        state <- GameTrace.states(seed),
        state.phase == phase,
        state.current_turn != nil,
        Engine.legal_actions(state, state.current_turn) != [],
        do: state
  end

  defp world_state(state, seed) do
    view = SeatView.for_seat(state, state.current_turn)
    {:ok, world, _rng} = Determinizer.sample(view, Determinizer.rng(seed))
    {view, Rollout.state(view, world)}
  end

  test "a sampled world looks the same from the seat that sampled it" do
    for state <- Enum.take_every(positions(:playing), 7) ++ positions(:bidding) do
      {view, world} = world_state(state, 1)
      again = SeatView.for_seat(world, view.position)

      for field <- [:hand, :phase, :bids, :highest_bid, :trump_suit, :tricks, :current_trick] do
        assert Map.fetch!(again, field) == Map.fetch!(view, field)
      end

      assert again.players == view.players
      assert again.killed_cards == view.killed_cards

      assert Engine.legal_actions(world, view.position) ==
               Engine.legal_actions(state, view.position)
    end
  end

  test "every candidate's rollout ends the hand through legal moves only" do
    for state <- Enum.take_every(positions(:playing), 9) ++ Enum.take(positions(:bidding), 30) do
      {view, world} = world_state(state, 2)

      for action <- Engine.legal_actions(world, view.position) do
        final = Rollout.run(world, view.position, action)

        assert final.phase in [:hand_complete, :complete]
        assert final.hand_number == world.hand_number
        assert is_number(Rollout.value(final, view.position))
      end
    end
  end

  test "a hand's value is my side's score change minus theirs, and a won game counts as the game" do
    {view, world} = world_state(hd(positions(:playing)), 3)
    action = hd(Engine.legal_actions(world, view.position))
    final = Rollout.run(world, view.position, action)
    team = Pidro.Core.Types.position_to_team(view.position)
    delta = final.last_hand.delta

    hand = delta[team] - delta[Pidro.Core.Types.opposing_team(team)]
    assert Rollout.value(final, view.position) == hand

    won = %{final | phase: :complete, winner: team}
    lost = %{final | phase: :complete, winner: Pidro.Core.Types.opposing_team(team)}
    assert Rollout.value(won, view.position) == hand + 62
    assert Rollout.value(lost, view.position) == hand - 62
  end
end
