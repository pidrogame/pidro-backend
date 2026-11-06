defmodule PidroServer.Games.AdminGameSummary do
  @moduledoc """
  Node-local, latest-only operational summaries in the existing game Registry.
  The `table` keeps only what everyone seated can see (cards on the felt,
  trump, bids, dealer, counts); no card in a hand and no action arguments. Only the registered game process
  can update its metadata; stopping it automatically removes its summary.
  Connected admin views sample the Registry's ETS; lobby lifecycle uses PubSub.
  """
  alias PidroServer.Games.GameRegistry

  @doc "Projects an engine snapshot in the publisher process, without a message queue."
  @spec record(String.t(), map()) :: :ok
  def record(code, state) do
    summary = %{
      phase: state.phase,
      current_turn: state.current_turn,
      trick_number: state.trick_number,
      cumulative_scores: state.cumulative_scores,
      hand_number: state.hand_number,
      pace: Map.get(state.config, :pace, :quick),
      last_event: event_name(List.last(state.events)),
      table: table(state)
    }

    # Presentation-only broadcasts must not pretend that somebody just moved.
    Registry.update_value(GameRegistry, code, fn previous ->
      if is_map(previous) and Map.delete(previous, :updated_at) == summary,
        do: previous,
        else: Map.put(summary, :updated_at, DateTime.utc_now())
    end)

    :ok
  rescue
    # Observability must not make a game fail during supervisor restart.
    ArgumentError -> :ok
  end

  @doc "Returns only the current game's summary, never an earlier rematch's cache."
  @spec get(String.t()) :: map() | nil
  def get(code) do
    case Registry.lookup(GameRegistry, code) do
      [{_pid, summary}] when is_map(summary) -> summary
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # What everyone at the table can see: cards on the felt, bids, trump, dealer,
  # hand points and card counts. Never a card still in somebody's hand.
  defp table(state) do
    %{
      dealer: state.current_dealer,
      trump: state.trump_suit,
      bid: state.highest_bid,
      bids: hand_bids(state.bids),
      trick: visible_trick(state),
      hand_points: state.hand_points,
      cards_left: Map.new(state.players, fn {pos, player} -> {pos, length(player.hand)} end),
      cold: for({pos, %{eliminated?: true}} <- state.players, do: pos),
      winner: state.winner
    }
  rescue
    # A malformed or legacy snapshot must not stop the game from being listed.
    _ -> nil
  end

  defp hand_bids(bids) when is_list(bids), do: Map.new(bids, &{&1.position, &1.amount})
  defp hand_bids(_), do: %{}

  # The fourth card completes the trick in the same action that clears it, so
  # an empty felt during play shows the trick just taken, with its winner.
  defp visible_trick(%{current_trick: %{plays: [_ | _]} = trick}), do: trick_view(trick)

  defp visible_trick(%{phase: phase, tricks: [_ | _] = tricks})
       when phase in [:playing, :scoring, :hand_complete],
       do: tricks |> List.last() |> trick_view()

  defp visible_trick(_), do: nil

  defp trick_view(trick) do
    %{
      number: trick.number,
      leader: trick.leader,
      plays: trick.plays,
      winner: trick.winner,
      points: trick.points
    }
  end

  defp event_name(nil), do: "Game started"
  defp event_name(event) when is_tuple(event), do: event |> elem(0) |> to_string()
  defp event_name(%{type: type}), do: to_string(type)
  defp event_name(_), do: "State changed"
end
