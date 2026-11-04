defmodule PidroServer.Leagues.Closer do
  @moduledoc "A minute tick; PostgreSQL owns the unique close claim across nodes."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:pidro_server, :league_timer, true), do: schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:close, state) do
    run()
    schedule()
    {:noreply, state}
  end

  defp run do
    PidroServer.Leagues.close_due()
  rescue
    error -> Logger.error("League close failed; next tick retries: #{Exception.message(error)}")
  end

  defp schedule, do: Process.send_after(self(), :close, :timer.minutes(1))
end
