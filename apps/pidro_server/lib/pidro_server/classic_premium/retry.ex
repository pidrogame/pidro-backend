defmodule PidroServer.ClassicPremium.Retry do
  @moduledoc """
  Keeps Classic Premium carried over (PID-391), once every `interval_ms`.

  Each run visits at most 200 players, one at a time: up to 150 carry-overs,
  `pending` ones younger than 30 days and every `granted` one, not tried in
  the last 20 hours, longest untried first, get
  `PidroServer.ClassicPremium.carry_over/1` again (which extends a grant
  when Classic's date moved); then the rest go to active `premium`
  entitlements not synced for 7 days, synced from RevenueCat. The first run
  is two minutes after boot, since every deploy restarts the node. Without
  RevenueCat configured a run does nothing.

  ## Configuration

      config :pidro_server, PidroServer.ClassicPremium.Retry,
        enabled: true,
        interval_ms: 86_400_000

  When `enabled` is false the process starts but never schedules a run;
  `run_once/0` still works. `config/test.exs` disables it, as for
  `PidroServer.Accounts.GuestReaper`: tests call `run_once/0` themselves.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PidroServer.ClassicPremium
  alias PidroServer.ClassicPremium.Carryover
  alias PidroServer.Entitlements
  alias PidroServer.Repo
  alias PidroServer.RevenueCat

  @limit 200
  @carryover_limit 150
  @first_run_ms 120_000
  @tried_within_hours 20
  @pending_days 30
  @stale_days 7
  @defaults [enabled: true, interval_ms: 86_400_000]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs once in the calling process and answers how many players had their
  carry-over tried again and how many entitlements were synced.
  """
  @spec run_once(keyword()) :: {:ok, %{carried: non_neg_integer(), synced: non_neg_integer()}}
  def run_once(_opts \\ []) do
    if RevenueCat.configured?(), do: run(), else: {:ok, %{carried: 0, synced: 0}}
  end

  defp run do
    carryovers = due_carryovers()

    Enum.each(
      carryovers,
      &ClassicPremium.carry_over(%{id: &1.user_id, classic_user_id: &1.classic_user_id})
    )

    stale = stale_entitlements(@limit - length(carryovers))
    Enum.each(stale, &sync/1)

    {:ok, %{carried: length(carryovers), synced: length(stale)}}
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(config(), opts)
    enabled? = config[:enabled] == true
    if enabled?, do: schedule(@first_run_ms)
    {:ok, %{enabled?: enabled?, interval_ms: config[:interval_ms]}}
  end

  @impl true
  def handle_info(:run, %{enabled?: true} = state) do
    case run_once() do
      {:ok, %{carried: 0, synced: 0}} -> :ok
      {:ok, counts} -> Logger.info("ClassicPremium.Retry ran: #{inspect(counts)}")
    end

    schedule(state.interval_ms)
    {:noreply, state}
  rescue
    exception ->
      Logger.error("ClassicPremium.Retry failed: " <> Exception.message(exception))
      schedule(state.interval_ms)
      {:noreply, state}
  end

  def handle_info(:run, state), do: {:noreply, state}

  defp due_carryovers do
    young = DateTime.add(DateTime.utc_now(), -@pending_days, :day)
    tried = DateTime.add(DateTime.utc_now(), -@tried_within_hours, :hour)

    Repo.all(
      from c in Carryover,
        where:
          ((c.state == "pending" and c.inserted_at > ^young) or c.state == "granted") and
            (is_nil(c.last_tried_at) or c.last_tried_at < ^tried),
        order_by: [asc_nulls_first: c.last_tried_at],
        limit: @carryover_limit
    )
  end

  defp stale_entitlements(0), do: []

  defp stale_entitlements(limit) do
    stale = DateTime.add(DateTime.utc_now(), -@stale_days, :day)

    Repo.all(
      from e in Entitlements.premium_now(),
        where: is_nil(e.last_synced_at) or e.last_synced_at < ^stale,
        order_by: [asc_nulls_first: e.last_synced_at],
        limit: ^limit,
        select: e.user_id
    )
  end

  defp sync(user_id) do
    with {:error, reason} <- Entitlements.sync_from_revenuecat(user_id) do
      Logger.error("ClassicPremium.Retry could not sync user #{user_id}: #{inspect(reason)}")
    end
  rescue
    exception ->
      Logger.error(
        "ClassicPremium.Retry could not sync user #{user_id}: #{Exception.message(exception)}"
      )
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :run, interval_ms)

  defp config, do: Keyword.merge(@defaults, Application.get_env(:pidro_server, __MODULE__, []))
end
