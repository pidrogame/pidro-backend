defmodule PidroServerWeb.InvitePage do
  @moduledoc """
  Pure presentation data for the public invite landing page and the player
  share page (`/play/:slug`), which share one layout.

  The invite state remains owned by `PidroServer.Invites`; this module only
  turns the public preview into honest copy and safe handoff URLs.
  """

  alias PidroServer.Invites
  alias PidroServer.Invites.Invite

  @iphone_install_url "https://www.pidro.online/beta"
  @play_store_base "https://play.google.com/store/apps/details?id=com.oneapps.pidro.beta"
  @android_package "com.oneapps.pidro.beta"
  @ios_scheme "pidro-mobile-beta"
  @seats_total 4

  @type device :: :ios | :android | :desktop | :crawler

  @doc "Builds the page assigns for a known public invite preview."
  @spec present(PidroServerWeb.InvitePreview.t(), device()) :: map()
  def present(%{invite: %Invite{} = invite} = preview, device) do
    target = target_invite(preview)
    target_url = Invites.url(target)
    host = preview.host || "A friend"
    state = preview.state

    show_qr = device == :desktop and state in [:open, :moved]
    content = state_content(state, host, preview.seats_taken)

    content
    |> Map.merge(%{
      state: state,
      code: target.code,
      canonical_url: Invites.url(invite),
      target_url: target_url,
      seats_taken: preview.seats_taken,
      seats_total: @seats_total,
      seat_copy: "#{preview.seats_taken} of #{@seats_total} seats taken",
      iphone_install_url: @iphone_install_url,
      play_store_url: play_store_url(target.code),
      ios_url: "#{@ios_scheme}://j/#{target.code}",
      android_url: android_intent(target_url, play_store_url(target.code)),
      device: device,
      show_qr: show_qr
    })
    |> Map.put(:qr_data_uri, if(show_qr, do: qr_data_uri(target_url)))
  end

  @doc "Builds generic page assigns for an unknown code without echoing it."
  @spec not_found(device()) :: map()
  def not_found(device) do
    %{
      state: :not_found,
      canonical_url: nil,
      title: "Come play Pidro",
      description: "This invite could not be found. Open Pidro to find a table and play.",
      eyebrow: "Invite not found",
      heading: "We couldn't find that invite",
      body:
        "The link may be incomplete or no longer available. You can still open Pidro and find a table.",
      table_action: :none,
      iphone_install_url: @iphone_install_url,
      play_store_url: @play_store_base,
      device: device
    }
  end

  @doc """
  Builds the page assigns for a player's share link: the player's name and
  avatar with an open-in-app handoff, or, for an unknown slug, the same page
  without a name.
  """
  @spec player(map() | nil, String.t(), device()) :: map()
  def player(%{display_name: name, avatar_url: avatar_url}, slug, device) do
    url = Invites.play_url(slug)

    %{
      found: true,
      canonical_url: url,
      title: "Play Pidro with #{name}",
      description: "#{name} plays Pidro. Get the app and join them at the table.",
      heading: "Play Pidro with #{name}",
      name: name,
      initial: String.first(name),
      avatar_url: avatar_url,
      iphone_install_url: @iphone_install_url,
      play_store_url: friend_play_store_url(slug),
      ios_url: "#{@ios_scheme}://play/#{slug}",
      android_url: android_intent(url, friend_play_store_url(slug)),
      deferred_capture_url:
        PidroServerWeb.DeferredInviteCaptureController.friend_capture_url(slug),
      device: device
    }
  end

  def player(nil, _slug, device) do
    %{
      found: false,
      canonical_url: nil,
      title: "Play Pidro",
      description: "Pidro is the Finnish card game for four. Get the app and play.",
      heading: "Play Pidro",
      deferred_capture_url: nil,
      iphone_install_url: @iphone_install_url,
      play_store_url: @play_store_base,
      device: device
    }
  end

  defp target_invite(%{state: :moved, invite: %Invite{successor: %Invite{} = successor}}),
    do: successor

  defp target_invite(%{invite: %Invite{} = invite}), do: invite

  defp state_content(:open, host, seats_taken) do
    %{
      title: "#{host} invited you to Pidro",
      description:
        "#{seats_taken} of #{@seats_total} seats are taken at #{host}'s Pidro table. Tap to join the game.",
      eyebrow: "You're invited",
      heading: "#{host} saved you a seat",
      body: "Open Pidro and join the table. No registration detour — pick a name and play.",
      table_action: :join
    }
  end

  defp state_content(:moved, host, _seats_taken) do
    %{
      title: "#{host} started a new Pidro table",
      description: "This table moved. Follow #{host} to the new Pidro table.",
      eyebrow: "New table",
      heading: "#{host} started a new table",
      body: "This invite moved with the host. Continue with the fresh table link.",
      table_action: :successor
    }
  end

  defp state_content(:full, _host, _seats_taken) do
    inactive("Table full", "This table is full", "All four seats have been claimed.")
  end

  defp state_content(:started, _host, _seats_taken) do
    inactive("Game in progress", "The game has already started", "This table is already playing.")
  end

  defp state_content(:locked, _host, _seats_taken) do
    inactive(
      "Table locked",
      "This table is locked",
      "The host isn't accepting new players right now."
    )
  end

  defp state_content(:closed, _host, _seats_taken) do
    inactive(
      "Table closed",
      "This table has closed",
      "The host may have left or the table timed out."
    )
  end

  defp state_content(:expired, _host, _seats_taken) do
    inactive("Invite expired", "This invite has expired", "Ask the host to share a fresh invite.")
  end

  defp state_content(:revoked, _host, _seats_taken) do
    inactive(
      "Invite inactive",
      "This invite is no longer active",
      "Ask the host to share a fresh invite."
    )
  end

  defp inactive(eyebrow, heading, body) do
    %{
      title: "#{eyebrow} · Pidro",
      description: "#{body} Open Pidro to find another table.",
      eyebrow: eyebrow,
      heading: heading,
      body: body,
      table_action: :none
    }
  end

  defp play_store_url(code) do
    referrer = URI.encode_www_form("invite=#{code}")
    "#{@play_store_base}&referrer=#{referrer}"
  end

  defp friend_play_store_url(slug) do
    "#{@play_store_base}&referrer=#{URI.encode_www_form("friend=#{URI.encode_www_form(slug)}")}"
  end

  defp android_intent(target_url, fallback_url) do
    uri = URI.parse(target_url)
    authority = uri.host <> port_suffix(uri.port, uri.scheme)
    fallback = URI.encode_www_form(fallback_url)

    "intent://#{authority}#{uri.path}#Intent;scheme=#{uri.scheme};" <>
      "package=#{@android_package};S.browser_fallback_url=#{fallback};end"
  end

  defp port_suffix(nil, _scheme), do: ""
  defp port_suffix(80, "http"), do: ""
  defp port_suffix(443, "https"), do: ""
  defp port_suffix(port, _scheme), do: ":#{port}"

  defp qr_data_uri(url) do
    svg = url |> EQRCode.encode(:m) |> EQRCode.svg(viewbox: true)
    "data:image/svg+xml;base64,#{Base.encode64(svg)}"
  end
end
