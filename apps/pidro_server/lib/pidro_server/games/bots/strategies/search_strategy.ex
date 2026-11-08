defmodule PidroServer.Games.Bots.Strategies.SearchStrategy do
  @moduledoc """
  The strategy of characters who play the odds.

  A thin adapter over `Pidro.Bot.Search` in the engine, which plays each
  candidate out in dealt worlds and overrules the rulebook only by a clear
  margin. It decides from the seat view alone and returns search's reason,
  which names both moves when they differ.
  """

  @behaviour PidroServer.Games.Bots.Strategy

  alias Pidro.Bot.Search
  alias Pidro.Core.SeatView

  @impl true
  @spec pick_action([term()], SeatView.t()) :: {:ok, term(), String.t()}
  def pick_action(legal_actions, %SeatView{} = view) do
    {action, reason} = Search.decide(view, legal_actions)
    {:ok, action, reason}
  end
end
