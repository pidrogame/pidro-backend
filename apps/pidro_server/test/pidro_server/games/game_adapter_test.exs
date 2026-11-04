defmodule PidroServer.Games.GameAdapterTest do
  use ExUnit.Case, async: false

  alias PidroServer.Games.{GameAdapter, Lifecycle}

  describe "transition_delay_ms/2" do
    test "holds the next hand for the hand's result and then its deal" do
      old_state = %{phase: :playing, hand_number: 1, tricks: [%{}], current_trick: nil}
      new_state = %{phase: :bidding, hand_number: 2, tricks: [], current_trick: nil}

      assert GameAdapter.transition_delay_ms(old_state, new_state) ==
               Lifecycle.config(:hand_transition_delay_ms) +
                 Lifecycle.config(:deal_transition_delay_ms)
    end

    test "returns trick transition delay when a trick completes" do
      old_state = %{
        phase: :playing,
        hand_number: 1,
        tricks: [],
        current_trick: %{plays: [1, 2, 3]}
      }

      new_state = %{
        phase: :playing,
        hand_number: 1,
        tricks: [%{winner: :north}],
        current_trick: nil
      }

      assert GameAdapter.transition_delay_ms(old_state, new_state) ==
               Lifecycle.config(:trick_transition_delay_ms)
    end

    test "at the shipped pacing a finished trick adds no pause at quick pace and 2.5 s at own pace" do
      original = Application.get_env(:pidro_server, Lifecycle)
      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)

      Config.Reader.read!(Path.expand("../../../../../config/config.exs", __DIR__), env: :prod)
      |> get_in([:pidro_server, Lifecycle])
      |> then(&Application.put_env(:pidro_server, Lifecycle, &1))

      old_state = %{
        phase: :playing,
        hand_number: 1,
        tricks: [],
        current_trick: %{plays: [1, 2, 3]}
      }

      new_state = %{
        phase: :playing,
        hand_number: 1,
        tricks: [%{winner: :north}],
        current_trick: nil
      }

      assert GameAdapter.transition_delay_ms(old_state, new_state) == 0

      assert GameAdapter.transition_delay_ms(old_state, put_in(new_state[:config], %{pace: :own})) ==
               2_500
    end

    test "holds play for the second deal once trump is named" do
      old_state = %{phase: :declaring, hand_number: 1, tricks: [], current_trick: nil}
      new_state = %{phase: :playing, hand_number: 1, tricks: [], current_trick: nil}

      assert GameAdapter.transition_delay_ms(old_state, new_state) ==
               Lifecycle.config(:second_deal_transition_delay_ms)
    end

    test "a dealer picking by hand plays on without the second deal's hold" do
      old_state = %{phase: :second_deal, hand_number: 1, tricks: [], current_trick: nil}
      new_state = %{phase: :playing, hand_number: 1, tricks: [], current_trick: nil}

      assert GameAdapter.transition_delay_ms(old_state, new_state) == 0
    end

    test "returns zero when the game is complete" do
      old_state = %{phase: :playing, hand_number: 1, tricks: [%{}], current_trick: nil}
      new_state = %{phase: :complete, hand_number: 2, tricks: [%{}, %{}], current_trick: nil}

      assert GameAdapter.transition_delay_ms(old_state, new_state) == 0
    end

    test "returns zero for normal in-hand updates" do
      old_state = %{phase: :playing, hand_number: 1, tricks: [], current_trick: %{plays: [1]}}
      new_state = %{phase: :playing, hand_number: 1, tricks: [], current_trick: %{plays: [1, 2]}}

      assert GameAdapter.transition_delay_ms(old_state, new_state) == 0
    end
  end
end
