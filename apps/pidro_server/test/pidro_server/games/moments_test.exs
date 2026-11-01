defmodule PidroServer.Games.MomentsTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Moments
  alias PidroServer.Games.Room.Positions

  doctest Moments

  @all [:north, :east, :south, :west]

  test "the dealer cut starts the game for everyone" do
    assert Moments.moments([{:dealer_selected, :west, {14, :hearts}}]) == [{"start", @all}]
  end

  test "a trick with points goes to the winner's partner only" do
    assert Moments.moments([{:trick_won, :north, 1}]) == [{"partner_trick", [:south]}]
    assert Moments.moments([{:trick_won, :south, 5}]) == [{"partner_trick", [:north]}]
    assert Moments.moments([{:trick_won, :east, 14}]) == [{"partner_trick", [:west]}]
    assert Moments.moments([{:trick_won, :west, 2}]) == [{"partner_trick", [:east]}]
  end

  test "a trick without points is no moment" do
    assert Moments.moments([{:trick_won, :north, 0}]) == []
  end

  test "the end of the game goes to everyone" do
    assert Moments.moments([{:game_won, :east_west, 62}]) == [{"game_end", @all}]
  end

  test "nothing in dealing, bidding, trump or discarding is a moment" do
    events = [
      {:cards_dealt, %{north: [], east: [], south: [], west: []}},
      {:bid_made, :east, 8},
      {:player_passed, :south},
      {:bidding_complete, :east, 8},
      {:trump_declared, :hearts},
      {:cards_discarded, :north, []},
      {:second_deal_complete, %{north: 6}},
      {:dealer_robbed_pack, :north, 3, 6},
      {:cards_killed, %{}},
      {:card_played, :north, {14, :hearts}},
      {:player_went_cold, :west, []},
      {:hand_scored, :north_south, 8}
    ]

    assert Moments.moments(events) == []
  end

  test "a real game played to its end gives start once, a partner for each trick with points, and game_end" do
    {:ok, state} = Pidro.Game.Dealing.select_dealer(Pidro.Core.GameState.new(seed: 7))
    {:ok, state} = Pidro.Game.Engine.advance_from_dealer_selection(state)
    final = play_out(state, 5_000)
    assert final.phase == :complete

    point_tricks = for {:trick_won, winner, points} <- final.events, points > 0, do: winner

    {starts, rest} =
      final.events |> Moments.moments() |> Enum.split_with(&match?({"start", _}, &1))

    {partners, ends} = Enum.split_with(rest, &match?({"partner_trick", _}, &1))

    assert starts == [{"start", @all}]
    assert point_tricks != []
    assert partners == for(w <- point_tricks, do: {"partner_trick", [Positions.partner(w)]})
    assert ends == [{"game_end", @all}]
  end

  test "several in one update keep their order" do
    events = [{:trick_won, :west, 1}, {:hand_scored, :east_west, 9}, {:game_won, :east_west, 62}]
    assert Moments.moments(events) == [{"partner_trick", [:east]}, {"game_end", @all}]
  end

  # Whoever may act takes their first legal action, until the game ends.
  defp play_out(%{phase: :complete} = state, _left), do: state

  defp play_out(state, left) when left > 0 do
    {seat, [action | _]} =
      Enum.find_value(@all, fn seat ->
        case Pidro.Game.Engine.legal_actions(state, seat) do
          [] -> nil
          actions -> {seat, actions}
        end
      end)

    {:ok, state} = Pidro.Game.Engine.apply_action(state, seat, action)
    play_out(state, left - 1)
  end
end
