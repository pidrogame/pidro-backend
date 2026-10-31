defmodule PidroServerWeb.Dev.BetaLive do
  @moduledoc """
  The beta report (PID-311): which rules people play, whether the two-minute
  promise holds, the pace of timed turns, and who comes back. Numbers come
  from `PidroServer.Stats.BetaReport`.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Stats.BetaReport

  @columns [accounts: "Accounts", guests: "Guests", all: "All"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Beta", columns: @columns)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    today = Date.utc_today()
    to = date_param(params["to"], today)
    from = date_param(params["from"], Date.add(to, -13))
    {from, to} = if Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}

    {:noreply, assign(socket, report: BetaReport.build(from, to, today), today: today)}
  end

  @impl true
  def handle_event("range", %{"from" => from, "to" => to}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/beta?#{[from: from, to: to]}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="beta"
      title="Beta players"
      subtitle="How the beta plays, from the server's own records: which rules, whether the two-minute promise holds, the pace, and who comes back. Beta players are everyone who has played a game here."
      flash={@flash}
    >
      <:actions>
        <form id="beta-range" phx-submit="range" class="flex flex-wrap items-end gap-2">
          <label class="text-xs font-medium text-stone-500">
            From
            <input
              type="date"
              name="from"
              value={@report.from}
              class="mt-1 block rounded-md border border-stone-300 px-2 py-1.5 text-sm text-stone-900"
            />
          </label>
          <label class="text-xs font-medium text-stone-500">
            To
            <input
              type="date"
              name="to"
              value={@report.to}
              class="mt-1 block rounded-md border border-stone-300 px-2 py-1.5 text-sm text-stone-900"
            />
          </label>
          <button
            type="submit"
            class="rounded-md bg-stone-950 px-3 py-2 text-sm font-semibold text-white hover:bg-stone-800"
          >
            Show
          </button>
          <.link
            href={~p"/admin/beta/classic.csv"}
            class="inline-flex items-center gap-2 rounded-md border border-stone-300 bg-white px-3 py-2 text-sm font-semibold text-stone-700 hover:text-stone-950"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Classic ids CSV
          </.link>
        </form>
      </:actions>

      <p class="text-sm text-stone-500">
        {@report.from} to {@report.to} (UTC). A game counts once in each column it belongs to, so a table with a guest and an account counts under both; All also counts deleted accounts.
      </p>

      <.metric_table
        id="beta-players"
        title="Who played"
        columns={@columns}
        rows={[
          {"Played in this range", @report.players, "Finished or started a game"}
        ]}
      />

      <.metric_table
        id="beta-rules"
        title="2 · Which rules?"
        columns={@columns}
        rows={
          Enum.flat_map(@report.rule_sets, fn rs ->
            name = rule_set_name(rs.rule_set)

            [
              {"#{name}: finished", rs.finished, "Games played to the end"},
              {"#{name}: closed early", rs.closed, "Everyone left before the end"}
            ]
          end)
        }
      />

      <.metric_table
        id="beta-promise"
        title="6 · Does the promise hold?"
        columns={@columns}
        rows={[
          {"Drops", @report.drops,
           "Gone mid-game: lost connection, or sent away after repeated timeouts"},
          {"Back within two minutes", @report.returns, "Took their seat back in time"},
          {"Seats a computer took over", @report.takeovers,
           "Left the game, or gone past two minutes"},
          {"Games started", @report.games_started, "From the game archive"},
          {"Seats a computer started in", @report.computer_seats, "Across those games"},
          {"Games finished", sum(@report.rule_sets, :finished), "Both rule sets"},
          {"Games lost to a server restart", sum(@report.rule_sets, :interrupted),
           "Cut off by a deploy or crash, not by players"}
        ]}
      />

      <.metric_table
        id="beta-pace"
        title="7 · Is the pace right?"
        columns={@columns}
        rows={[
          {"Timed turns", @report.timed_turns, "Turns on the clock: tables with other people"},
          {"Turns timed out", @report.timeouts, "The clock ran out and the server played"},
          {"Median time per turn", seconds(@report.median_turn_ms), "Timed turns, including timeouts"}
        ]}
      />

      <.metric_table
        id="beta-return"
        title="8 · Do they stay?"
        columns={@columns}
        rows={[
          {"First played in this range", @report.new_players, "Day 1 is their first day"},
          {"Back on day 2", share(@report.day2), "Played again the next day"},
          {"Back on day 7", share(@report.day7), "Played again six days after day 1"}
        ]}
      />

      <p class="text-xs leading-5 text-stone-500">
        Started games, early endings and computer seats come from the game archive, which keeps 30 days; after that, a day on which a player only started games no longer counts as a day played. Guest or account is as the player is today. A player counts as due for day 2 or day 7 once that day is over, or as soon as they are back on it. Whether they still play the old app: compare the Classic ids CSV with Classic's records.
      </p>
    </.admin_shell>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :columns, :list, required: true
  attr :rows, :list, required: true

  defp metric_table(assigns) do
    ~H"""
    <section id={@id} class="overflow-hidden rounded-lg border border-stone-200 bg-white">
      <h2 class="border-b border-stone-200 px-4 py-3 text-sm font-semibold text-stone-950">
        {@title}
      </h2>
      <table class="min-w-full divide-y divide-stone-200 text-sm">
        <thead class="bg-stone-50">
          <tr>
            <th class="px-4 py-2 text-left text-xs font-medium text-stone-500"></th>
            <th
              :for={{_key, label} <- @columns}
              class="w-40 px-4 py-2 text-right text-xs font-medium text-stone-500"
            >
              {label}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-stone-100">
          <tr :for={{label, values, hint} <- @rows}>
            <td class="px-4 py-2.5">
              <span class="font-medium text-stone-900">{label}</span>
              <span class="ml-2 text-xs text-stone-500">{hint}</span>
            </td>
            <td
              :for={{key, _label} <- @columns}
              class="whitespace-nowrap px-4 py-2.5 text-right font-mono tabular-nums text-stone-900"
            >
              {values[key]}
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp date_param(value, default) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> default
    end
  end

  defp date_param(_value, default), do: default

  defp rule_set_name("finnish"), do: "Finnish"
  defp rule_set_name("louisiana"), do: "Louisiana"

  defp sum(rule_sets, key) do
    Map.new(@columns, fn {column, _} ->
      {column, rule_sets |> Enum.map(&get_in(&1, [key, column])) |> Enum.sum()}
    end)
  end

  defp seconds(medians) do
    Map.new(medians, fn
      {column, nil} -> {column, "–"}
      {column, ms} -> {column, "#{:erlang.float_to_binary(ms / 1000, decimals: 1)} s"}
    end)
  end

  defp share(%{returned: returned, due: due}) do
    Map.new(@columns, fn {column, _} ->
      {column, share_text(returned[column], due[column])}
    end)
  end

  defp share_text(_returned, 0), do: "–"
  defp share_text(returned, due), do: "#{returned} of #{due} (#{round(returned / due * 100)}%)"
end
