defmodule PidroServer.Games.Bots.BotBrainTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Bots.BotBrain

  describe "compute_delay/3" do
    test "returns the base delay when variance is zero" do
      assert BotBrain.compute_delay(250, 0, 100) == 250
    end

    test "stays within the configured range and respects the minimum floor" do
      Enum.each(1..50, fn _ ->
        delay = BotBrain.compute_delay(20, 30, 15)
        assert delay >= 15
        assert delay <= 50
      end)
    end

    test "at the shipped quick pace a bot acts exactly 2000 ms after the action before it" do
      path = Path.expand("../../../../../../config/config.exs", __DIR__)

      lifecycle =
        Config.Reader.read!(path, env: :prod)[:pidro_server][PidroServer.Games.Lifecycle]

      Enum.each(1..50, fn _ ->
        assert BotBrain.compute_delay(
                 lifecycle[:bot_delay_ms],
                 lifecycle[:bot_delay_variance_ms],
                 lifecycle[:bot_min_delay_ms]
               ) == 2_000
      end)
    end
  end

  describe "schedule_move_once/3" do
    test "marks state as scheduled and only queues one move" do
      opts = [base_delay_ms: 0, variance_ms: 0, min_delay_ms: 0]

      state = BotBrain.schedule_move_once(%{move_scheduled?: false}, 0, opts)
      assert state.move_scheduled?
      assert_receive :make_move, 50

      same_state = BotBrain.schedule_move_once(state, 0, opts)
      assert same_state == state
      refute_receive :make_move, 50
    end

    test "adds transition delay to the scheduled move" do
      opts = [base_delay_ms: 0, variance_ms: 0, min_delay_ms: 0]

      _state = BotBrain.schedule_move_once(%{move_scheduled?: false}, 40, opts)

      refute_receive :make_move, 20
      assert_receive :make_move, 80
    end
  end
end
