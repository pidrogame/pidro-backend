defmodule PidroServer.GameArchive.SerializationTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.GameState
  alias Pidro.Test.DeterministicGame
  alias PidroServer.GameArchive.Serialization

  # A restored game continues from the decoded state, so every state a game
  # passes through, chance stream and events included, must come back equal.
  test "every state of whole games decodes back to the engine state it was" do
    for variant <- [:finnish, :louisiana], seed <- [3, 17, 2_026], pace <- [:quick, :own] do
      GameState.new(seed: seed, variant: variant, config: %{pace: pace})
      |> Pidro.Game.Dealing.select_dealer()
      |> elem(1)
      |> Pidro.Game.Engine.advance_from_dealer_selection()
      |> elem(1)
      |> Stream.iterate(&next/1)
      |> Enum.take_while(&(&1 != :done))
      |> Enum.each(fn state ->
        json = state |> Serialization.encode() |> Jason.encode!() |> Jason.decode!()
        assert Serialization.decode_game(json) == state
      end)
    end
  end

  test "decoding refuses anything but the engine's own terms" do
    assert_raise KeyError, fn -> Serialization.decode_game(%{"$struct" => "Elixir.File.Stat"}) end

    assert_raise ArgumentError, fn ->
      Serialization.decode_game("an atom nobody ever made #{System.unique_integer()}")
    end
  end

  defp next(%{phase: :complete}), do: :done

  defp next(%{phase: :hand_complete} = state) do
    {:ok, state} = Pidro.Game.Engine.continue_hand(state)
    state
  end

  defp next(state), do: DeterministicGame.step(state)
end
