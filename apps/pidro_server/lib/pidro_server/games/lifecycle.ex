defmodule PidroServer.Games.Lifecycle do
  @moduledoc """
  Centralized configuration for all timeout values in the disconnect cascade
  and room lifecycle.

  All values are in milliseconds and can be overridden via application config:

      config :pidro_server, PidroServer.Games.Lifecycle,
        hiccup_timeout_ms: 20_000

  Or via environment variables in runtime.exs for production tuning.

  `invited_waiting_ttl_ms` is the idle time after which the abandoned-room
  sweep closes a `:waiting` room with no connected human while one of its
  invites is still live (`LIFECYCLE_INVITED_WAITING_TTL_MS`); without a live
  invite the sweep keeps its five-minute grace period.

  `sweep_trick_delay_ms` paces a settled hand: once one player alone holds
  trumps, the server plays their remaining trumps one trick this far apart.
  """

  @type timeout_key ::
          :hiccup_timeout_ms
          | :grace_timeout_ms
          | :empty_room_ttl_ms
          | :finished_room_ttl_ms
          | :idle_waiting_ttl_ms
          | :invited_waiting_ttl_ms
          | :reconnect_turn_extension_ms
          | :health_check_interval_ms
          | :presence_debounce_ms
          | :turn_timer_bid_ms
          | :turn_timer_play_ms
          | :consecutive_timeout_threshold
          | :bot_delay_ms
          | :own_bot_delay_ms
          | :bot_delay_variance_ms
          | :bot_min_delay_ms
          | :dealer_selection_delay_ms
          | :trick_transition_delay_ms
          | :own_trick_transition_delay_ms
          | :sweep_trick_delay_ms
          | :hand_transition_delay_ms
          | :second_deal_transition_delay_ms
          | :deal_transition_delay_ms

  @defaults %{
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
    # The hand's result stays ~6 s with no button; the next hand's deal then
    # adds deal_transition_delay_ms.
    hand_transition_delay_ms: 6_000,
    # As long as the client plays the second deal out (Classic's pace): each
    # player's throw, the piles to count, the refill card by card, the
    # dealer's pile held 2 s (~10.96 s for a 12-card refill), plus a breath
    # so killed trumps show before the first card.
    second_deal_transition_delay_ms: 11_500,
    # As long as the client deals every hand's nine cards (12 packets 260 ms
    # apart, the 588 ms pause, the 560 ms sort: ~4.3 s), plus a breath.
    deal_transition_delay_ms: 5_000
  }

  @doc """
  Returns the configured value for the given timeout key, falling back to the
  built-in default if no override is set.

  ## Examples

      iex> PidroServer.Games.Lifecycle.config(:hiccup_timeout_ms)
      20_000

      iex> PidroServer.Games.Lifecycle.config(:grace_timeout_ms)
      120_000
  """
  @spec config(timeout_key()) :: non_neg_integer()
  def config(key) when is_map_key(@defaults, key) do
    app_config = Application.get_env(:pidro_server, __MODULE__, [])
    Keyword.get(app_config, key, Map.fetch!(@defaults, key))
  end

  @doc """
  Returns the full map of default timeout values.
  """
  @spec defaults() :: %{timeout_key() => non_neg_integer()}
  def defaults, do: @defaults
end
