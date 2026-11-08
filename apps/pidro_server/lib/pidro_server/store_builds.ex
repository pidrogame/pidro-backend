defmodule PidroServer.StoreBuilds do
  @moduledoc """
  Release advice from store snapshots, the effective News policy and recent
  players. Store builds, minimums and player counts are all maps with a
  `version` and a build `number` (iOS build number, Android version code);
  a minimum's or a player's number may be nil.
  """
  import Ecto.Query
  alias PidroServer.Repo
  alias PidroServer.Stats.SeatEvent
  alias PidroServer.StoreBuilds.Cache

  @all_good "Both stores have their newest build out, and older installs are nudged to update."

  def player_versions do
    since = DateTime.add(DateTime.utc_now(), -7, :day)

    from(e in SeatEvent,
      where: e.inserted_at > ^since and not is_nil(e.app_version),
      group_by: [e.platform, e.app_version, e.app_build],
      order_by: [e.platform, e.app_version, e.app_build],
      select: %{
        platform: e.platform,
        version: e.app_version,
        number: e.app_build,
        count: count(e.user_id, :distinct)
      }
    )
    |> Repo.all()
  end

  @doc "The policy's minimum per platform: its version and, where set, its build."
  def minimums(policy) do
    for {platform, version} <- policy.minimum_native_versions,
        version not in [nil, ""],
        into: %{},
        do: {platform, %{version: version, number: policy.minimum_native_builds[platform]}}
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
          {"#{name(platform)} #{build_label(newest)} never reached players",
           "iPhone: #{build_label(newest)} is only in the Team group. Add it to Friends and submit it for review."}

        platform == "android" and newest.track == "internal" and
            (data.live == nil or newer_build?(newest, data.live)) ->
          {"#{name(platform)} #{build_label(newest)} never reached players",
           "Android: #{build_label(newest)} is only in internal testing. Release it to open testing and check that the beta track is completed."}

        data.live == nil ->
          {"No #{name(platform)} build is live",
           "#{name(platform)}: no build is live for players. #{state_label(newest.state)}."}

        newest.version == data.live.version and newer_build?(newest, data.live) ->
          {pending_title(platform, newest),
           "#{name(platform)}: #{build_label(newest)} is #{state_phrase(newest.state)}. Players can install #{build_label(data.live)}."}

        newer_build?(newest, data.live) ->
          {pending_title(platform, newest),
           "#{name(platform)}: #{build_label(newest)} is #{state_phrase(newest.state)}. Players are on #{build_label(data.live)} and get no new-version over-the-air updates until it is live."}

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

      below?(data.live, minimum) ->
        steps ++
          [
            step(
              platform,
              "#{name(platform)} minimum is above live",
              "#{name(platform)}: the minimum #{build_label(minimum)} is above the live build #{build_label(data.live)}. Lower it; the store does not have that update yet.",
              :news
            )
          ]

      pending == nil and (minimum == nil or newer_build?(data.live, minimum)) ->
        older = unnudged(counts, platform, data.live, minimum)

        if older > 0 do
          [
            step(
              platform,
              "Nudge #{name(platform)} players to #{build_label(data.live)}",
              "#{name(platform)} #{build_label(data.live)} is live, but players below it aren't nudged. Publish an app-update post. #{older} player-build records below it in the last 7 days.",
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
        "Submit #{name(platform)} #{build_label(newest)} for review"

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

  # Players below the live build whom the minimum does not nudge yet.
  defp unnudged(counts, platform, live, minimum) do
    counts
    |> Enum.filter(&(&1.platform == platform and below?(&1, live) and !below?(&1, minimum)))
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
        pending -> stop("Players", :todo, "Still #{build_label(live)}", group(platform))
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

      below?(live, minimum) ->
        stop("Nudge", :now, notice_from(minimum), "above live")

      pending ->
        stop("Nudge", :todo, "Not yet", "after review")

      unnudged(counts, platform, live, minimum) > 0 ->
        stop("Nudge", :now, notice_from(minimum), "publish a post")

      minimum != nil and !above?(live.version, minimum.version) ->
        stop("Nudge", :done, notice_from(minimum), "store notice on")

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
  defp notice_from(nil), do: "Not set"
  defp notice_from(minimum), do: "From #{build_label(minimum)}"

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
  This week's players per version and build, newest first, each `:newest`
  (on the build players can get or will get after review), `:nudged` (below
  the minimum) or `:older`, with a one-line summary.
  """
  def players(platform, store, minimum, counts) do
    %{newest: newest, live: live} = store.data || %{newest: nil, live: nil}
    stuck = newest && pending?(newest, live) && stuck(platform, newest)
    target = if newest && !stuck, do: newest, else: live

    segments =
      for count <- counts,
          count.platform == platform do
        kind =
          cond do
            below?(count, minimum) -> :nudged
            at_least?(count, target) -> :newest
            true -> :older
          end

        Map.put(count, :kind, kind)
      end
      |> Enum.sort(&(!newer_build?(&2, &1)))

    total = Enum.sum_by(segments, & &1.count)
    sum = fn kind -> segments |> Enum.filter(&(&1.kind == kind)) |> Enum.sum_by(& &1.count) end

    summary =
      cond do
        total == 0 ->
          "no players recorded"

        target == nil ->
          "#{total} players"

        stuck && target != newest ->
          "nobody can get #{build_label(newest)} yet"

        newest != nil and target == newest and live != nil and newer_build?(newest, live) ->
          waiting = segments |> Enum.reject(&newer_build?(&1, live)) |> Enum.sum_by(& &1.count)

          if newest.state in ~w(WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW inProgress),
            do:
              "#{waiting} of #{total} wait for #{if platform == "ios", do: "Apple", else: "Google Play"}",
            else: "#{waiting} of #{total} can't get #{build_label(newest)} yet"

        sum.(:older) > 0 ->
          "#{sum.(:older)} of #{total} not nudged"

        sum.(:nudged) > 0 ->
          "#{sum.(:nudged)} of #{total} still to update"

        true ->
          "all #{total} up to date"
      end

    %{segments: segments, summary: summary}
  end

  @doc """
  Whether a release needs a step, such as a review, a Team-only build or a
  nudge. A store that is unchecked or failed its check doesn't count: Play
  is unchecked after every deploy. Reads the cache; never asks a store.
  """
  def attention? do
    minimums = minimums(PidroServer.News.native_update_policy())
    counts = player_versions()

    Enum.any?(Cache.snapshot(), fn {platform, store} ->
      store.error == nil and store.data != nil and
        release_steps(platform, store.data, minimums[platform], counts) != []
    end)
  end

  # A missing build counts as 0: a 3.3.0 minimum without one leaves 3.3.0 (14) un-nudged.
  defp newer_build?(newest, live) do
    above?(newest.version, live.version) or
      (newest.version == live.version and
         (number(newest.number) || 0) > (number(live.number) || 0))
  end

  @doc """
  Whether `build` is below `other` as the News nudge sees it: a lower
  version, or the same version with a lower build where both have one.
  """
  def below?(build, other) when is_map(build) and is_map(other) do
    above?(other.version, build.version) or
      (build.version == other.version and lower?(number(build.number), number(other.number)))
  end

  def below?(_build, _other), do: false

  defp lower?(number, other) when is_integer(number) and is_integer(other), do: number < other
  defp lower?(_number, _other), do: false

  defp at_least?(build, %{} = target),
    do:
      above?(build.version, target.version) or
        (build.version == target.version and !below?(build, target))

  defp at_least?(_build, nil), do: false

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_value), do: nil

  def above?(version, other) when is_binary(version) and is_binary(other) do
    with {:ok, version} <- Version.parse(version), {:ok, other} <- Version.parse(other) do
      Version.compare(version, other) == :gt
    else
      _ -> false
    end
  end

  def above?(_, _), do: false

  @doc """
  The app-update form's minimums from what players can install: the live
  version and its build (App Store Connect build number, Play version code),
  else the current minimum.
  """
  def live_versions(stores, minimums \\ %{}) do
    Enum.reduce(~w(android ios), %{}, fn platform, params ->
      live = get_in(stores, [platform, :data, :live])
      minimum = if live && live.version, do: live, else: minimums[platform] || %{}

      Map.merge(params, %{
        "show_below_#{platform}" => minimum[:version] || "",
        "show_below_#{platform}_build" => minimum[:number] || ""
      })
    end)
  end

  def hint(store) do
    cond do
      store.error == :not_connected ->
        "Store not connected; verify the live version in the console."

      store.data == nil ->
        "Live version is not known yet."

      store.error != nil ->
        "Store check failed; last known live build: #{build_label(store.data.live)}."

      store.data.live == nil ->
        "No build is live for players yet."

      store.data.live.version == nil ->
        "The live release name is not an app version; verify it in the console."

      store.data.newest && newer_build?(store.data.newest, store.data.live) ->
        "#{build_label(store.data.newest)} is #{state_phrase(store.data.newest.state)}; players are on #{build_label(store.data.live)}"

      true ->
        "Live for players now: #{build_label(store.data.live)}"
    end
  end

  def name("ios"), do: "iPhone"
  def name("android"), do: "Android"
  def store_name("ios"), do: "App Store Connect"
  def store_name("android"), do: "Google Play"
  def build_label(nil), do: "None known"
  def build_label(%{number: number} = build) when number in [nil, ""], do: build.version
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
