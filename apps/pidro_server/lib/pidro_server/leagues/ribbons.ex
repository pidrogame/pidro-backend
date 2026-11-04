defmodule PidroServer.Leagues.Ribbons do
  @moduledoc "Monthly ribbons derived from weekly participation, never a carried tier."
  alias PidroServer.Leagues

  @doc "UTC month key used on the wire."
  def month(at), do: Calendar.strftime(at, "%Y-%m")

  @doc "All Sunday close moments in a calendar month."
  def closes(month) do
    first = Date.from_iso8601!(month <> "-01")

    first
    |> Date.range(Date.end_of_month(first))
    |> Enum.filter(&(Date.day_of_week(&1) == 7))
    |> Enum.map(&DateTime.new!(&1, ~T[19:00:00], "Etc/UTC"))
  end

  @doc "A single ribbon from result rows and, optionally, the running membership."
  def ribbon(results, month, now, running \\ nil) do
    played =
      for r <- results,
          month(r.week_closes_at) == month,
          do: {r.week_closes_at, [r.old_league, r.new_league]}

    played =
      case running do
        {closes, league} ->
          if month(closes) == month, do: [{closes, [league]} | played], else: played

        nil ->
          played
      end

    if played != [] do
      dates = MapSet.new(played, fn {at, _} -> DateTime.to_unix(at) end)
      all = closes(month)
      elapsed = Enum.filter(all, &(DateTime.compare(&1, now) != :gt))
      so_far = month(now) == month
      best = played |> Enum.flat_map(&elem(&1, 1)) |> Enum.max_by(&rank/1)

      %{
        month: month,
        league: best,
        star: MapSet.size(dates) == length(all),
        weeks_played: MapSet.size(dates),
        weeks_total: length(all),
        so_far: so_far,
        star_possible: so_far and Enum.all?(elapsed, &MapSet.member?(dates, DateTime.to_unix(&1)))
      }
    end
  end

  @doc "The current ribbon and up to twelve finished months, oldest first."
  def list(results, now, running) do
    current = month(now)

    past =
      results
      |> Enum.map(&month(&1.week_closes_at))
      |> Enum.uniq()
      |> Enum.filter(&(&1 < current))
      |> Enum.sort()
      |> Enum.take(-12)
      |> Enum.map(&ribbon(results, &1, now))

    %{current: ribbon(results, current, now, running), past: past}
  end

  defp rank(league), do: Enum.find_index(Leagues.leagues(), &(&1 == league))
end
