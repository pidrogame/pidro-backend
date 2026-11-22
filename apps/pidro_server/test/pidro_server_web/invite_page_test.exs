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
        assert page.iphone_install_url == "http://localhost:4002/get"
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
        assert page.iphone_install_url == "http://localhost:4002/get"
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

  describe "switch day" do
    setup do
      app = Application.get_env(:pidro_server, InvitePage)
      on_exit(fn -> Application.put_env(:pidro_server, InvitePage, app) end)
    end

    test "runtime.exs gives the beta app by default and the production app from the env" do
      runtime = Path.expand("../../../../config/runtime.exs", __DIR__)

      env = %{
        "NATIVE_ANDROID_PACKAGE" => "com.oneapps.pidro",
        "NATIVE_APP_SCHEME" => "pidro-mobile",
        "STORE_BUILDS_ASC_APP_ID" => "1137091987",
        "STORE_BUILDS_PLAY_PACKAGE" => "com.oneapps.pidro",
        "STORE_BUILDS_IOS_TRACK" => "app_store",
        "STORE_BUILDS_PLAY_TRACK" => "production"
      }

      read = fn ->
        config = Config.Reader.read!(runtime, env: :test)[:pidro_server]

        {config[InvitePage],
         Keyword.take(config[PidroServer.StoreBuilds.Client], [
           :asc_app_id,
           :play_package,
           :ios_track,
           :play_track
         ])}
      end

      on_exit(fn -> Enum.each(Map.keys(env), &System.delete_env/1) end)
      Enum.each(Map.keys(env), &System.delete_env/1)

      assert read.() ==
               {[android_package: "com.oneapps.pidro.beta", app_scheme: "pidro-mobile-beta"],
                [
                  asc_app_id: "6816832730",
                  play_package: "com.oneapps.pidro.beta",
                  ios_track: "testflight",
                  play_track: "beta"
                ]}

      System.put_env(env)

      assert read.() ==
               {[android_package: "com.oneapps.pidro", app_scheme: "pidro-mobile"],
                [
                  asc_app_id: "1137091987",
                  play_package: "com.oneapps.pidro",
                  ios_track: "app_store",
                  play_track: "production"
                ]}
    end

    test "invite and player pages open the configured app: beta by default, production after" do
      player = %{display_name: "Aino", avatar_url: nil}

      for {package, scheme} <- [
            {"com.oneapps.pidro.beta", "pidro-mobile-beta"},
            {"com.oneapps.pidro", "pidro-mobile"}
          ] do
        if package == "com.oneapps.pidro" do
          Application.put_env(:pidro_server, InvitePage,
            android_package: package,
            app_scheme: scheme
          )
        end

        invite = InvitePage.present(preview(:open), :android)
        friend = InvitePage.player(player, "aino", :ios)

        assert invite.ios_url == "#{scheme}://j/AAAAAAAA"
        assert friend.ios_url == "#{scheme}://play/aino"

        for page <- [invite, friend] do
          assert [_, ^package] = Regex.run(~r/;package=([^;]+);/, page.android_url)
        end
      end
    end
  end

  describe "install_target/1" do
    setup do
      app = Application.get_env(:pidro_server, InvitePage)
      on_exit(fn -> Application.put_env(:pidro_server, InvitePage, app) end)
    end

    test "during the beta, iPhone and desktop get the beta page and Android the beta listing" do
      Application.put_env(:pidro_server, :native_store_urls, %{
        "ios" => "https://testflight.apple.com/join/2JR95b65",
        "android" => "https://play.google.com/store/apps/details?id=com.oneapps.pidro.beta"
      })

      assert InvitePage.install_url() == "http://localhost:4002/get"
      assert InvitePage.install_target(:ios) == "http://localhost:4002/beta"
      assert InvitePage.install_target(:desktop) == "http://localhost:4002/beta"
      assert InvitePage.install_target(:crawler) == "http://localhost:4002/beta"

      assert InvitePage.install_target(:android) ==
               "https://play.google.com/store/apps/details?id=com.oneapps.pidro.beta"
    end

    test "after switch day, phones get their stores and desktop the home page" do
      Application.put_env(:pidro_server, :native_store_urls, %{
        "ios" => "https://apps.apple.com/app/id1137091987",
        "android" => "https://play.google.com/store/apps/details?id=com.oneapps.pidro"
      })

      Application.put_env(:pidro_server, InvitePage,
        android_package: "com.oneapps.pidro",
        app_scheme: "pidro-mobile"
      )

      assert InvitePage.install_target(:ios) == "https://apps.apple.com/app/id1137091987"

      assert InvitePage.install_target(:android) ==
               "https://play.google.com/store/apps/details?id=com.oneapps.pidro"

      assert InvitePage.install_target(:desktop) == "http://localhost:4002/"
      assert InvitePage.install_target(:crawler) == "http://localhost:4002/"
    end

    test "a missing store falls back to the page for desktop" do
      Application.put_env(:pidro_server, :native_store_urls, %{})
      assert InvitePage.install_target(:android) == "http://localhost:4002/beta"

      Application.put_env(:pidro_server, InvitePage,
        android_package: "com.oneapps.pidro",
        app_scheme: "pidro-mobile"
      )

      assert InvitePage.install_target(:ios) == "http://localhost:4002/"
      assert InvitePage.install_target(:android) == "http://localhost:4002/"
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
