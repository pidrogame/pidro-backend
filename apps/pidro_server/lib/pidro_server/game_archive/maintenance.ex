defmodule PidroServer.GameArchive.Maintenance do
  @moduledoc "Bounded reconciliation and retention for the single-node game registry."
  use GenServer
  import Ecto.Query
  require Logger

  alias PidroServer.GameArchive
  alias PidroServer.GameArchive.Archive
  alias PidroServer.Games.{GameRegistry, RoomStore}
  alias PidroServer.Repo

  @doc "Starts periodic maintenance; disabled under the SQL sandbox."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reconciles up to 100 active instances after an exclusive ID cursor; returns next cursor (or nil)."
  @spec reconcile(String.t() | nil) :: String.t() | nil
  def reconcile(after_id \\ nil) do
    cutoff = DateTime.add(DateTime.utc_now(), -120, :second)

    query =
      from a in Archive,
        where: a.status == "active" and a.saved_at < ^cutoff,
        order_by: a.game_instance_id,
        limit: 100,
        select: {a.game_instance_id, a.room_code}

    query = if after_id, do: where(query, [a], a.game_instance_id > ^after_id), else: query
    rows = Repo.all(query)

    for {id, room} <- rows do
      if missing_instance?(room, id),
        do: GameArchive.finalize(id, "interrupted", "process_missing")
    end

    if length(rows) == 100, do: rows |> List.last() |> elem(0), else: nil
  end

  @impl true
  def init(_opts) do
    GameArchive.cache_versions()
    config = Application.get_env(:pidro_server, __MODULE__, [])
    interval = Keyword.get(config, :interval_ms, 60_000)

    unless is_integer(interval) and interval >= 1_000,
      do: raise(ArgumentError, "invalid archive maintenance interval")

    # The deployment has one serving node, with a 60s deploy timeout and 30s
    # drain. Do not mistake the old container's games for dead during overlap.
    if Keyword.get(config, :enabled, true), do: Process.send_after(self(), :sweep, 120_000)

    {:ok,
     %{
       cursor: nil,
       interval: interval,
       cleanup: Keyword.take(config, [:retention_days, :batch_size])
     }}
  end

  @impl true
  def handle_info(:sweep, state) do
    cursor = sweep(state)
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, %{state | cursor: cursor}}
  end

  defp sweep(state) do
    cursor = reconcile(state.cursor)
    GameArchive.cleanup(state.cleanup)
    cursor
  rescue
    _ ->
      Logger.error("Game archive maintenance failed; retrying next interval")
      state.cursor
  end

  # A game an open room still runs is alive on whichever node owns the room,
  # or about to be restored there.
  defp missing_instance?(room, id) do
    case GameRegistry.lookup(room) do
      {:error, :not_found} -> not RoomStore.live_instance?(id)
      {:ok, pid} -> Pidro.Server.get_snapshot(pid, 1_000).game_instance_id != id
    end
  catch
    # A busy or unreachable process is not evidence of death. Check again later.
    :exit, _ -> false
  end
end
