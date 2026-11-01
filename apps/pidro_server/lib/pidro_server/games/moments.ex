defmodule PidroServer.Games.Moments do
  @moduledoc """
  The moments a table may answer with a face or a word (PID-328), read from
  the events the engine already emits. Each is `{id, seats}`, the seats it is
  pushed to. No bidding event is a moment.

  | Event                          | id              | Seats                |
  |--------------------------------|-----------------|----------------------|
  | `:dealer_selected`, once a game | `start`         | all four             |
  | `:trick_won` with points in it | `partner_trick` | the winner's partner |
  | `:game_won`                    | `game_end`      | all four             |

  Only human seats have a channel, so a bot partner receives nothing.
  """

  alias PidroServer.Games.Room.Positions

  @seats [:north, :east, :south, :west]

  @doc """
  The moments in `events`, in order.

      iex> PidroServer.Games.Moments.moments([{:trick_won, :east, 0}, {:trick_won, :east, 5}])
      [{"partner_trick", [:west]}]
  """
  @spec moments([tuple()]) :: [{String.t(), [Positions.position()]}]
  def moments(events), do: Enum.flat_map(events, &moment/1)

  defp moment({:dealer_selected, _position, _card}), do: [{"start", @seats}]

  defp moment({:trick_won, winner, points}) when points > 0,
    do: [{"partner_trick", [Positions.partner(winner)]}]

  defp moment({:game_won, _team, _score}), do: [{"game_end", @seats}]
  defp moment(_event), do: []
end
