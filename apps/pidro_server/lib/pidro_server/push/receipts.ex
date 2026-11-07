defmodule PidroServer.Push.Receipts do
  @moduledoc "Reads Expo's push receipts every 5 minutes. Off in tests, which call `Push.check_receipts/0`."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Keyword.get(Application.get_env(:pidro_server, __MODULE__, []), :enabled, true),
      do: schedule()

    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    run()
    schedule()
    {:noreply, state}
  end

  defp run do
    PidroServer.Push.check_receipts()
  rescue
    error ->
      Logger.error("Push receipts failed; the next run retries: #{Exception.message(error)}")
  end

  defp schedule, do: Process.send_after(self(), :check, :timer.minutes(5))
end
