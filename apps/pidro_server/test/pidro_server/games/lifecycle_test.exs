defmodule PidroServer.Games.LifecycleTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Lifecycle

  @all_keys [
    :hiccup_timeout_ms,
    :grace_timeout_ms,
    :empty_room_ttl_ms,
    :finished_room_ttl_ms,
    :idle_waiting_ttl_ms,
    :invited_waiting_ttl_ms,
    :reconnect_turn_extension_ms,
    :health_check_interval_ms,
    :presence_debounce_ms,
    :turn_timer_bid_ms,
    :turn_timer_play_ms,
    :consecutive_timeout_threshold,
    :bot_delay_ms,
    :own_bot_delay_ms,
    :bot_delay_variance_ms,
    :bot_min_delay_ms,
    :dealer_selection_delay_ms,
    :trick_transition_delay_ms,
    :own_trick_transition_delay_ms,
    :sweep_trick_delay_ms,
    :hand_transition_delay_ms,
    :second_deal_transition_delay_ms,
    :deal_transition_delay_ms
  ]

  @expected_defaults %{
    hiccup_timeout_ms: 20_000,
    grace_timeout_ms: 120_000,
    empty_room_ttl_ms: 30_000,
    finished_room_ttl_ms: 300_000,
    idle_waiting_ttl_ms: 600_000,
    invited_waiting_ttl_ms: 7_200_000,
    reconnect_turn_extension_ms: 10_000,
    health_check_interval_ms: 60_000,
    presence_debounce_ms: 3_000,
    turn_timer_bid_ms: 45_000,
    turn_timer_play_ms: 30_000,
    consecutive_timeout_threshold: 3,
    bot_delay_ms: 1_500,
    own_bot_delay_ms: 2_500,
    bot_delay_variance_ms: 800,
    bot_min_delay_ms: 300,
    dealer_selection_delay_ms: 3_000,
    trick_transition_delay_ms: 1_500,
    own_trick_transition_delay_ms: 2_500,
    sweep_trick_delay_ms: 500,
    hand_transition_delay_ms: 6_000,
    second_deal_transition_delay_ms: 11_500,
    deal_transition_delay_ms: 5_000
  }

  describe "config/1" do
    test "returns default values when no config override is set" do
      original = Application.get_env(:pidro_server, Lifecycle)
      Application.delete_env(:pidro_server, Lifecycle)

      on_exit(fn ->
        if original, do: Application.put_env(:pidro_server, Lifecycle, original)
      end)

      for key <- @all_keys do
        assert Lifecycle.config(key) == @expected_defaults[key],
               "expected default for #{key} to be #{@expected_defaults[key]}, got #{Lifecycle.config(key)}"
      end
    end

    test "returns overridden value when Application config is set" do
      original = Application.get_env(:pidro_server, Lifecycle)
      Application.put_env(:pidro_server, Lifecycle, hiccup_timeout_ms: 5_000)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, Lifecycle, original),
          else: Application.delete_env(:pidro_server, Lifecycle)
      end)

      assert Lifecycle.config(:hiccup_timeout_ms) == 5_000
    end

    test "non-overridden keys still return defaults when some keys are overridden" do
      original = Application.get_env(:pidro_server, Lifecycle)
      Application.put_env(:pidro_server, Lifecycle, grace_timeout_ms: 60_000)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, Lifecycle, original),
          else: Application.delete_env(:pidro_server, Lifecycle)
      end)

      assert Lifecycle.config(:grace_timeout_ms) == 60_000
      assert Lifecycle.config(:hiccup_timeout_ms) == 20_000
      assert Lifecycle.config(:empty_room_ttl_ms) == 30_000
    end

    test "raises FunctionClauseError for unknown keys" do
      assert_raise FunctionClauseError, fn ->
        Lifecycle.config(:nonexistent_key)
      end
    end
  end

  describe "defaults/0" do
    test "returns all timeout and pacing keys" do
      defaults = Lifecycle.defaults()
      assert map_size(defaults) == length(@all_keys)

      for key <- @all_keys do
        assert Map.has_key?(defaults, key), "missing key: #{key}"
      end
    end

    test "returns expected default values" do
      assert Lifecycle.defaults() == @expected_defaults
    end

    test "all values are positive integers" do
      for {key, value} <- Lifecycle.defaults() do
        assert is_integer(value) and value > 0,
               "expected #{key} to be a positive integer, got #{inspect(value)}"
      end
    end
  end
end
