defmodule PidroServer.StoreBuilds do
  @moduledoc "Release advice from store snapshots, the effective News policy and recent players."
  import Ecto.Query
  alias PidroServer.Repo
  alias PidroServer.Stats.SeatEvent
  alias PidroServer.StoreBuilds.Cache

  @all_good "Both stores have their newest build out, and older installs are nudged to update."

  def player_versions do
    since = DateTime.add(DateTime.utc_now(), -7, :day)

    from(e in SeatEvent,
      where: e.inserted_at > ^since and not is_nil(e.app_version),
      group_by: [e.platform, e.app_version],
      order_by: [e.platform, e.app_version],
      select: %{platform: e.platform, version: e.app_version, count: count(e.user_id, :distinct)}
    )
    |> Repo.all()
  end

  def next_steps(stores, minimums, counts) do
    steps =
      Enum.flat_map(~w(ios android), fn platform ->
        store = stores[platform]

        cond do
          store.error == :not_connected ->
            [
              step(
                platform,
                "Can't read #{name(platform)} builds",
                "#{store_name(platform)} not connected"
              )
            ]

          store.error != nil ->
            [
              step(
                platform,
                "#{store_name(platform)} check failed",
                "#{name(platform)}: #{store.error} #{if store.data, do: "Last good data is shown below;", else: "No successful check yet;"} verify the store before publishing."
              )
            ]

          store.data == nil ->
            [
              step(
                platform,
                "#{name(platform)} not checked yet",
                "#{name(platform)}: no store check yet. Press Refresh to check."
              )
            ]

          true ->
            release_steps(platform, store.data, minimums[platform], counts)
        end
      end)

    if steps == [],
      do: [
        %{
          platform: nil,
          tone: :good,
          title: "Everyone can get the latest",
          text: @all_good,
          action: nil
        }
      ],
      else: steps
  end

  defp step(platform, title, text, action \\ nil, tone \\ :waiting),
    do: %{platform: platform, tone: tone, title: title, text: text, action: action}

  defp release_steps(platform, data, minimum, counts) do
    newest = data.newest

    pending =
      cond do
        newest == nil ->
          {"No #{name(platform)} builds", "#{name(platform)}: no store builds found."}

        platform == "ios" and !newest.friends and newest.team ->
          {"#{name(platform)} #{newest.version} never reached players",
           "iPhone: #{build_label(newest)} is only in the Team group. Add it to Friends and submit it for review."}

        platform == "android" and newest.track == "internal" and
            (data.live == nil or newer_build?(newest, data.live)) ->
          {"#{name(platform)} #{newest.version} never reached players",
           "Android: #{build_label(newest)} is only in internal testing. Release it to open testing and check that the beta track is completed."}

        data.live == nil ->
          {"No #{name(platform)} build is live",
           "#{name(platform)}: no build is live for players. #{state_label(newest.state)}."}

        newest.version == data.live.version and newer_build?(newest, data.live) ->
          {pending_title(platform, newest),
           "#{name(platform)}: #{build_label(newest)} is #{state_phrase(newest.state)}. Players can install #{build_label(data.live)}."}

        newer_build?(newest, data.live) ->
          {pending_title(platform, newest),
           "#{name(platform)}: #{newest.version} is #{state_phrase(newest.state)}. Players are on #{data.live.version} and get no new-version over-the-air updates until it is live."}

        true ->
          nil
      end

    steps =
      case pending do
        nil ->
          []

        {title, text} ->
          [
            step(
              platform,
              title,
              text,
              nil,
              if(stuck(platform, newest), do: :stuck, else: :waiting)
            )
          ]
      end

    cond do
      data.live == nil ->
        steps

      data.live.version == nil ->
        steps ++
          [
            step(
              platform,
              "Check the #{name(platform)} release name",
              "#{name(platform)}: the live release name is not an app version. Verify its native version in the console before publishing an app-update post."
            )
          ]

      above?(minimum, data.live.version) ->
        steps ++
          [
            step(
              platform,
              "#{name(platform)} minimum is above live",
              "#{name(platform)}: the minimum #{minimum} is above the live version #{data.live.version}. Lower it; the store does not have that update yet.",
              :news
            )
          ]

      pending == nil and (minimum in [nil, ""] or above?(data.live.version, minimum)) ->
        older = below(counts, platform, data.live.version)

        if older > 0 do
          [
            step(
              platform,
              "Nudge #{name(platform)} players to #{data.live.version}",
              "#{name(platform)} #{data.live.version} is live, but players below it aren't nudged. Publish an app-update post. #{older} player-version records below it in the last 7 days.",
              :news
            )
          ]
        else
          steps
        end

      true ->
        steps
    end
  end

  defp pending_title(platform, newest) do
    case newest.state do
      state when state in ["WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"] ->
        "Waiting on Apple"

      "READY_FOR_BETA_SUBMISSION" ->
        "Submit #{name(platform)} #{newest.version} for review"

      state ->
        "#{name(platform)} #{build_label(newest)} is #{state_phrase(state)}"
    end
  end

  # A newer build that cannot reach players until someone acts in the console.
  defp stuck("ios", %{friends: false, team: true}), do: {"Team only", "not in Friends"}
  defp stuck("android", %{track: "internal"}), do: {"Internal only", "not in open testing"}

  defp stuck(_platform, %{state: state}) when state in ~w(BETA_REJECTED INVALID FAILED EXPIRED),
    do: {state_label(state), nil}

  defp stuck(_platform, _build), do: nil

  defp below(counts, platform, version) do
    counts
    |> Enum.filter(&(&1.platform == platform and above?(version, &1.version)))
    |> Enum.map(& &1.count)
    |> Enum.sum()
  end

  @doc """
  The newest build's way to players as four stops (Uploaded, Review, Players,
  Nudge), each `:done`, `:now`, `:stuck` or `:todo` with a value and a note.
  """
  def rail(platform, store, minimum, counts, now)

  def rail(_platform, %{data: nil}, _minimum, _counts, _now),
    do: for(label <- ~w(Uploaded Review Players Nudge), do: stop(label, :todo, "—"))

  def rail(platform, %{data: %{newest: newest, live: live}}, minimum, counts, now) do
    pending = pending?(newest, live)

    [
      if(newest,
        do: stop("Uploaded", :done, build_label(newest), day(newest.uploaded_at)),
        else: stop("Uploaded", :todo, "None")
      ),
      review_stop(platform, newest, pending, now),
      cond do
        live == nil -> stop("Players", :todo, "Nobody yet", group(platform))
        pending -> stop("Players", :todo, "Still #{live.version || live.number}", group(platform))
        true -> stop("Players", :done, "Live", group(platform))
      end,
      nudge_stop(platform, live, pending, minimum, counts)
    ]
  end

  defp review_stop(platform, newest, pending, now) do
    cond do
      newest == nil ->
        stop("Review", :todo, "—")

      !pending ->
        stop("Review", :done, if(platform == "ios", do: "Approved", else: "Passed"))

      reason = stuck(platform, newest) ->
        {value, note} = reason
        stop("Review", :stuck, value, note)

      newest.state in ["WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"] ->
        stop(
          "Review",
          :now,
          if(newest.state == "IN_BETA_REVIEW", do: "In review", else: "Waiting"),
          waited(time(newest[:submitted_at]) || time(newest.uploaded_at), now)
        )

      newest.state == "READY_FOR_BETA_SUBMISSION" ->
        stop("Review", :now, "Not submitted")

      true ->
        stop("Review", :now, state_label(newest.state))
    end
  end

  defp nudge_stop(platform, live, pending, minimum, counts) do
    cond do
      live == nil ->
        stop("Nudge", :todo, "Not yet")

      live.version == nil ->
        stop("Nudge", :now, "Check version", "release name")

      above?(minimum, live.version) ->
        stop("Nudge", :now, "From #{minimum}", "above live")

      pending ->
        stop("Nudge", :todo, "Not yet", "after review")

      minimum not in [nil, ""] and !above?(live.version, minimum) ->
        stop("Nudge", :done, "From #{minimum}", "store notice on")

      below(counts, platform, live.version) > 0 ->
        stop("Nudge", :now, notice_from(minimum), "publish a post")

      true ->
        stop("Nudge", :done, notice_from(minimum), "nobody to nudge")
    end
  end

  defp stop(label, status, value, note \\ nil),
    do: %{label: label, status: status, value: value, note: note}

  defp pending?(nil, _live), do: false
  defp pending?(_newest, nil), do: true
  defp pending?(newest, live), do: newer_build?(newest, live)

  defp group("ios"), do: "Friends group"
  defp group("android"), do: "open testing"
  defp notice_from(minimum) when minimum in [nil, ""], do: "Not set"
  defp notice_from(minimum), do: "From #{minimum}"

  defp time(%DateTime{} = at), do: at

  defp time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp time(_at), do: nil

  defp day(at), do: if(at = time(at), do: Calendar.strftime(at, "%-d %b"))

  defp waited(nil, _now), do: nil

  defp waited(at, now) do
    case DateTime.diff(now, at, :hour) do
      hours when hours >= 48 -> "for #{div(hours, 24)} days"
      hours when hours >= 24 -> "for 1 day"
      hours when hours >= 1 -> "for #{hours} h"
      _ -> "for under an hour"
    end
  end

  @doc """
  This week's players per version, newest first, each `:newest` (on the build
  players can get or will get after review), `:nudged` (below the minimum) or
  `:older`, with a one-line summary.
  """
  def players(platform, store, minimum, counts) do
    %{newest: newest, live: live} = store.data || %{newest: nil, live: nil}
    stuck = newest && pending?(newest, live) && stuck(platform, newest)
    target = if newest && !stuck, do: newest.version, else: live && live.version

    segments =
      for count <- counts,
          count.platform == platform do
        kind =
          cond do
            above?(minimum, count.version) -> :nudged
            count.version == target or above?(count.version, target) -> :newest
            true -> :older
          end

        Map.put(count, :kind, kind)
      end
      |> Enum.sort(&(!above?(&2.version, &1.version)))

    total = Enum.sum_by(segments, & &1.count)
    sum = fn kind -> segments |> Enum.filter(&(&1.kind == kind)) |> Enum.sum_by(& &1.count) end

    summary =
      cond do
        total == 0 ->
          "no players recorded"

        target == nil ->
          "#{total} players"

        stuck && target != newest.version ->
          "nobody can get #{newest.version} yet"

        newest != nil and target == newest.version and above?(target, live && live.version) ->
          waiting =
            segments |> Enum.reject(&above?(&1.version, live.version)) |> Enum.sum_by(& &1.count)

          if newest.state in ~w(WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW inProgress),
            do:
              "#{waiting} of #{total} wait for #{if platform == "ios", do: "Apple", else: "Google Play"}",
            else: "#{waiting} of #{total} can't get #{newest.version} yet"

        sum.(:older) > 0 ->
          "#{sum.(:older)} of #{total} not nudged"

        sum.(:nudged) > 0 ->
          "#{sum.(:nudged)} of #{total} still to update"

        true ->
          "all #{total} up to date"
      end

    %{segments: segments, summary: summary}
  end

  @doc "Whether Store builds needs a look. Reads the cache; never asks a store."
  def attention? do
    policy = PidroServer.News.native_update_policy()

    Cache.snapshot()
    |> next_steps(policy.minimum_native_versions, player_versions())
    |> Enum.any?(&(&1.tone != :good))
  end

  defp newer_build?(newest, live) do
    above?(newest.version, live.version) or
      (newest.version == live.version and number(newest.number) > number(live.number))
  end

  defp number(value) do
    case Integer.parse(value || "") do
      {n, ""} -> n
      _ -> 0
    end
  end

  def above?(version, other) when is_binary(version) and is_binary(other) do
    with {:ok, version} <- Version.parse(version), {:ok, other} <- Version.parse(other) do
      Version.compare(version, other) == :gt
    else
      _ -> false
    end
  end

  def above?(_, _), do: false

  def live_versions(stores, minimums \\ %{}) do
    Map.new(~w(android ios), fn platform ->
      {"show_below_#{platform}",
       get_in(stores, [platform, :data, :live, :version]) || minimums[platform] || ""}
    end)
  end

  def hint(store) do
    cond do
      store.error == :not_connected ->
        "Store not connected; verify the live version in the console."

      store.data == nil ->
        "Live version is not known yet."

      store.error != nil ->
        "Store check failed; last known live version: #{build_label(store.data.live)}."

      store.data.live == nil ->
        "No build is live for players yet."

      store.data.live.version == nil ->
        "The live release name is not an app version; verify it in the console."

      store.data.newest && newer_build?(store.data.newest, store.data.live) ->
        "#{store.data.newest.version} is #{state_phrase(store.data.newest.state)}; players are on #{store.data.live.version}"

      true ->
        "Live for players now: #{store.data.live.version}"
    end
  end

  def name("ios"), do: "iPhone"
  def name("android"), do: "Android"
  def store_name("ios"), do: "App Store Connect"
  def store_name("android"), do: "Google Play"
  def build_label(nil), do: "None known"
  def build_label(build), do: "#{build.version || "Unknown version"} (#{build.number})"

  defp state_phrase(state) do
    label = state_label(state)
    String.replace_prefix(label, String.first(label), String.downcase(String.first(label)))
  end

  def state_label(state) do
    Map.get(
      %{
        "WAITING_FOR_BETA_REVIEW" => "Waiting for Apple's review",
        "IN_BETA_REVIEW" => "In Apple's review",
        "IN_BETA_TESTING" => "Testing",
        "READY_FOR_BETA_TESTING" => "Ready for external testing",
        "READY_FOR_BETA_SUBMISSION" => "Ready to submit for review",
        "BETA_REJECTED" => "Rejected by Apple",
        "PROCESSING" => "Processing",
        "VALID" => "Processed",
        "INVALID" => "Invalid build",
        "FAILED" => "Processing failed",
        "EXPIRED" => "Expired",
        "completed" => "Live",
        "draft" => "Draft",
        "inProgress" => "Rolling out",
        "halted" => "Rollout paused"
      },
      state,
      "Unknown state — check the console"
    )
  end
end
