defmodule PidroServer.StoreBuilds do
  @moduledoc "Release advice from store snapshots, the effective News policy and recent players."
  import Ecto.Query
  alias PidroServer.Repo
  alias PidroServer.Stats.SeatEvent

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
            [%{text: "#{store_name(platform)} not connected", action: nil}]

          store.error != nil ->
            [
              %{
                text:
                  "#{name(platform)}: #{store.error} #{if store.data, do: "Last good data is shown below;", else: "No successful check yet;"} verify the store before publishing.",
                action: nil
              }
            ]

          store.data == nil ->
            [
              %{
                text: "#{name(platform)}: no store check yet. Press Refresh to check.",
                action: nil
              }
            ]

          true ->
            release_steps(platform, store.data, minimums[platform], counts)
        end
      end)

    if steps == [], do: [%{text: "All good", action: nil}], else: steps
  end

  defp release_steps(platform, data, minimum, counts) do
    pending =
      cond do
        data.newest == nil ->
          "#{name(platform)}: no store builds found."

        platform == "ios" and !data.newest.friends and data.newest.team ->
          "iPhone: #{build_label(data.newest)} is only in the Team group. Add it to Friends and submit it for review."

        platform == "android" and data.newest.track == "internal" and
            (data.live == nil or newer_build?(data.newest, data.live)) ->
          "Android: #{build_label(data.newest)} is only in internal testing. Release it to open testing and check that the beta track is completed."

        data.live == nil ->
          "#{name(platform)}: no build is live for players. #{state_label(data.newest.state)}."

        data.newest.version == data.live.version and newer_build?(data.newest, data.live) ->
          "#{name(platform)}: #{build_label(data.newest)} is #{state_phrase(data.newest.state)}. Players can install #{build_label(data.live)}."

        newer_build?(data.newest, data.live) ->
          "#{name(platform)}: #{data.newest.version} is #{state_phrase(data.newest.state)}. Players are on #{data.live.version} and get no new-version over-the-air updates until it is live."

        true ->
          nil
      end

    steps = if pending, do: [%{text: pending, action: nil}], else: []

    cond do
      data.live == nil ->
        steps

      data.live.version == nil ->
        steps ++
          [
            %{
              text:
                "#{name(platform)}: the live release name is not an app version. Verify its native version in the console before publishing an app-update post.",
              action: nil
            }
          ]

      above?(minimum, data.live.version) ->
        steps ++
          [
            %{
              text:
                "#{name(platform)}: the minimum #{minimum} is above the live version #{data.live.version}. Lower it; the store does not have that update yet.",
              action: :news
            }
          ]

      minimum in [nil, ""] or above?(data.live.version, minimum) ->
        older =
          counts
          |> Enum.filter(&(&1.platform == platform and above?(data.live.version, &1.version)))
          |> Enum.map(& &1.count)
          |> Enum.sum()

        detail =
          if older > 0,
            do: " #{older} player-version records below it in the last 7 days.",
            else: ""

        steps ++
          [
            %{
              text:
                "#{name(platform)} #{data.live.version} is live, but players below it aren't nudged. Publish an app-update post.#{detail}",
              action: :news
            }
          ]

      true ->
        steps
    end
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
