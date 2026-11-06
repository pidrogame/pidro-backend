defmodule PidroServerWeb.InvitePageTest do
  use ExUnit.Case, async: false

  alias PidroServer.Invites.Invite
  alias PidroServerWeb.InvitePage
  alias PidroServerWeb.InvitePage.UserAgent

  setup do
    urls = Application.get_env(:pidro_server, :native_store_urls)
    on_exit(fn -> Application.put_env(:pidro_server, :native_store_urls, urls) end)
  end

  test "all store destinations follow configuration while preserving install referrers" do
    for android <- [
          "https://example.com/android",
          "https://example.com/android?id=public#install",
          "https://example.com/android?id=public&referrer=campaign&referrer=old#install"
        ] do
      Application.put_env(:pidro_server, :native_store_urls, %{
        "ios" => "https://example.com/ios?campaign=launch",
        "android" => android
      })

      invite = InvitePage.present(preview(:open), :android)
      player = InvitePage.player(%{display_name: "Aino", avatar_url: nil}, "aino", :android)

      for {page, referrer} <- [{invite, "invite=AAAAAAAA"}, {player, "friend=aino"}] do
        assert page.iphone_install_url == "https://example.com/ios?campaign=launch"
        uri = URI.parse(page.play_store_url)
        base = URI.parse(android)
        assert %{uri | query: nil} == %{base | query: nil}

        assert URI.decode_query(uri.query) ==
                 Map.put(URI.decode_query(base.query || ""), "referrer", referrer)

        assert uri.query
               |> URI.query_decoder()
               |> Enum.filter(fn {key, _} -> key == "referrer" end) ==
                 [{"referrer", referrer}]

        assert page.android_url =~
                 "S.browser_fallback_url=#{URI.encode_www_form(page.play_store_url)};"
      end

      for page <- [InvitePage.not_found(:ios), InvitePage.player(nil, "unknown", :desktop)] do
        assert page.iphone_install_url == "https://example.com/ios?campaign=launch"
        assert page.play_store_url == android
      end
    end
  end

  test "missing store destinations never fall back to a beta listing" do
    Application.put_env(:pidro_server, :native_store_urls, %{})

    for page <- [
          InvitePage.present(preview(:open), :android),
          InvitePage.player(%{display_name: "Aino", avatar_url: nil}, "aino", :android)
        ] do
      assert page.iphone_install_url == nil
      assert page.play_store_url == nil
      assert page.android_url =~ "package=com.oneapps.pidro.beta;end"
      refute page.android_url =~ "browser_fallback_url"
    end
  end

  describe "present/2" do
    test "open copy includes live seat context and only desktop builds a QR" do
      preview = preview(:open, seats_taken: 2)

      ios = InvitePage.present(preview, :ios)
      desktop = InvitePage.present(preview, :desktop)

      assert ios.description =~ "2 of 4 seats"
      assert ios.table_action == :join
      assert ios.qr_data_uri == nil
      assert desktop.qr_data_uri =~ "data:image/svg+xml;base64,"
    end

    test "crawler presentation skips QR generation" do
      page = InvitePage.present(preview(:open), :crawler)

      assert page.show_qr == false
      assert page.qr_data_uri == nil
    end

    test "moved invites consistently hand off to and display the successor" do
      successor = %Invite{code: "BBBBBBBB"}
      invite = %Invite{code: "AAAAAAAA", successor: successor}
      page = InvitePage.present(preview(:moved, invite: invite), :desktop)

      assert page.code == successor.code
      assert page.target_url =~ successor.code
      assert page.canonical_url =~ invite.code
      assert page.android_url =~ "/j/#{successor.code}#Intent"
    end

    test "every inactive state has honest copy and no join action" do
      states = [
        full: "full",
        started: "started",
        locked: "locked",
        closed: "closed",
        expired: "expired",
        revoked: "no longer active"
      ]

      Enum.each(states, fn {state, message} ->
        page = state |> preview() |> InvitePage.present(:ios)

        assert page.heading =~ message
        assert page.table_action == :none
        assert page.show_qr == false
        assert page.qr_data_uri == nil
      end)
    end
  end

  describe "UserAgent.classify/1" do
    test "recognizes supported share crawlers before device families" do
      for token <- ~w(
            Applebot Discordbot facebookexternalhit Facebot iMessage LinkedInBot Slackbot
            TelegramBot Twitterbot WhatsApp
          ) do
        assert UserAgent.classify("Mozilla/5.0 #{token} iPhone Android") == :crawler
      end
    end

    test "classifies iOS, iPad desktop mode, Android and unknown agents" do
      assert UserAgent.classify("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)") == :ios
      assert UserAgent.classify("Mozilla/5.0 (Macintosh) AppleWebKit Mobile/15E148") == :ios
      assert UserAgent.classify("Mozilla/5.0 (Linux; Android 15)") == :android
      assert UserAgent.classify(nil) == :desktop
      assert UserAgent.classify("curl/8.7.1") == :desktop
    end
  end

  defp preview(state, overrides \\ []) do
    invite = Keyword.get(overrides, :invite, %Invite{code: "AAAAAAAA"})

    %{
      invite: invite,
      state: state,
      host: "Marcel",
      seats_taken: Keyword.get(overrides, :seats_taken, 1)
    }
  end
end
