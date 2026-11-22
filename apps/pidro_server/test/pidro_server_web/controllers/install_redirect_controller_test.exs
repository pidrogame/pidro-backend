defmodule PidroServerWeb.InstallRedirectControllerTest do
  use PidroServerWeb.ConnCase, async: false

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
  @android "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/131.0 Mobile"
  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"

  setup do
    urls = Application.get_env(:pidro_server, :native_store_urls)
    app = Application.get_env(:pidro_server, PidroServerWeb.InvitePage)

    on_exit(fn ->
      Application.put_env(:pidro_server, :native_store_urls, urls)
      Application.put_env(:pidro_server, PidroServerWeb.InvitePage, app)
    end)
  end

  defp get_install(agent) do
    conn = build_conn() |> put_req_header("user-agent", agent) |> get(~p"/get")
    assert conn.status == 302
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [vary] = get_resp_header(conn, "vary")
    assert String.downcase(vary) == "user-agent"
    assert get_resp_header(conn, "set-cookie") == []
    redirected_to(conn)
  end

  test "during the beta: iPhone and desktop to /beta, Android to the beta's Play listing" do
    Application.put_env(:pidro_server, :native_store_urls, %{
      "ios" => "https://testflight.apple.com/join/2JR95b65",
      "android" => "https://play.google.com/store/apps/details?id=com.oneapps.pidro.beta"
    })

    assert get_install(@iphone) == "http://localhost:4002/beta"
    assert get_install(@desktop) == "http://localhost:4002/beta"

    assert get_install(@android) ==
             "https://play.google.com/store/apps/details?id=com.oneapps.pidro.beta"
  end

  test "after switch day: iPhone to the App Store, Android to Google Play, desktop home" do
    Application.put_env(:pidro_server, :native_store_urls, %{
      "ios" => "https://apps.apple.com/app/id1137091987",
      "android" => "https://play.google.com/store/apps/details?id=com.oneapps.pidro"
    })

    Application.put_env(:pidro_server, PidroServerWeb.InvitePage,
      android_package: "com.oneapps.pidro",
      app_scheme: "pidro-mobile"
    )

    assert get_install(@iphone) == "https://apps.apple.com/app/id1137091987"

    assert get_install(@android) ==
             "https://play.google.com/store/apps/details?id=com.oneapps.pidro"

    assert get_install(@desktop) == "http://localhost:4002/"
  end
end
