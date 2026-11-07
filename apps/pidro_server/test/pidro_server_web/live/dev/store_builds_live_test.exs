defmodule PidroServerWeb.Dev.StoreBuildsLiveTest do
  use PidroServerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias PidroServer.StoreBuilds.{Cache, Client}
  alias PidroServer.News

  setup :register_and_log_in_admin

  setup do
    Req.Test.set_req_test_to_shared()

    f =
      File.read!(Path.expand("../../../fixtures/store_builds.json", __DIR__))
      |> Jason.decode!()

    old = Application.get_env(:pidro_server, Client, [])
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    rsa = :public_key.generate_key({:rsa, 2048, 65_537})
    rsa_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])

    Application.put_env(:pidro_server, Client,
      asc_key_id: "test",
      asc_issuer_id: "test",
      asc_private_key: pem,
      play_service_account_json:
        Jason.encode!(%{client_email: "test@example.com", private_key: rsa_pem}),
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:store_request, conn.method, conn.request_path})

      body =
        case conn.request_path do
          "/v1/builds" ->
            f["asc"]

          "/v1/apps/6816832730/betaGroups" ->
            f["groups"]

          "/v1/betaGroups/friends/builds" ->
            f["friends"]

          "/v1/betaGroups/team/builds" ->
            f["team"]

          "/token" ->
            %{access_token: "test"}

          "/androidpublisher/v3/applications/com.oneapps.pidro.beta/edits" ->
            %{id: "test"}

          "/androidpublisher/v3/applications/com.oneapps.pidro.beta/edits/test/tracks" ->
            f["play"]

          "/androidpublisher/v3/applications/com.oneapps.pidro.beta/edits/test" ->
            %{}
        end

      Req.Test.json(conn, body)
    end)

    Cache.subscribe()
    Cache.refresh("ios")
    await_check()
    Cache.refresh("android")
    await_check()

    on_exit(fn ->
      Application.put_env(:pidro_server, Client, old)
      Application.delete_env(:pidro_server, Cache)
      Supervisor.terminate_child(PidroServer.Supervisor, Cache)
      Supervisor.restart_child(PidroServer.Supervisor, Cache)
    end)

    :ok
  end

  test "admin page, both-platform draft, advisory warning, failed refresh and recovery", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/admin/store-builds")
    assert html =~ "Next steps"
    assert has_element?(view, "#store-ios", "3.2.4 (10)")
    assert has_element?(view, "#store-ios", "3.2.1 (7)")
    assert has_element?(view, "#store-android", "production: 3.2.3 (8)")
    assert has_element?(view, "#store-android", "from deploy config")

    result = view |> element("#next-steps li:last-child a") |> render_click()
    {:ok, news, _} = follow_redirect(result, conn, "/admin/news?app_update=true")
    assert has_element?(news, "input[name='post[show_below_android]'][value='3.2.4']")
    assert has_element?(news, "input[name='post[show_below_ios]'][value='3.2.1']")
    assert has_element?(news, "#store-hint-ios", "players are on 3.2.1")

    news
    |> form("#news-form",
      post: %{title_en: "Future update", body_en: "Soon", show_below_ios: "3.2.4"}
    )
    |> render_change()

    assert has_element?(news, "#store-hint-ios [role=alert]", "doesn't have 3.2.4 yet")
    news |> form("#news-form") |> render_submit()
    assert Enum.any?(News.list_all(), &(&1.title_en == "Future update"))

    {:ok, view, _} = live(conn, ~p"/admin/store-builds")
    before = Cache.snapshot()
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "secret body") end)
    view |> element("#refresh-ios") |> render_click()
    failed = await_check()
    assert failed["ios"].data == before["ios"].data
    assert failed["ios"].good_at == before["ios"].good_at
    assert failed["ios"].error =~ "HTTP 503"
    assert render(view) =~ "Last good data"
    refute render(view) =~ "secret body"

    Application.put_env(:pidro_server, Client, [])
    Cache.refresh("ios")
    await_check()
    Cache.refresh("android")
    await_check()
    assert render(view) =~ "App Store Connect not connected"
    assert render(view) =~ "Google Play not connected"
  end

  test "anonymous visitors cannot read store builds" do
    assert {:error, {:redirect, %{to: "/admin/login"}}} =
             live(build_conn(), ~p"/admin/store-builds")
  end

  test "Play reads require an explicit button; startup, timer and both page loads read only Apple",
       %{conn: conn} do
    drain_requests()
    :ok = Supervisor.terminate_child(PidroServer.Supervisor, Cache)
    {:ok, _} = Supervisor.restart_child(PidroServer.Supervisor, Cache)
    await_check()
    assert_receive {:store_request, "GET", "/v1/builds"}
    refute_receive {:store_request, "POST", _}
    assert Cache.snapshot()["android"].checked_at == nil

    send(Process.whereis(Cache), :refresh)
    await_check()
    assert_receive {:store_request, "GET", "/v1/builds"}
    refute_receive {:store_request, "POST", _}

    {:ok, stores, _} = live(conn, ~p"/admin/store-builds")
    {:ok, news, _} = live(conn, ~p"/admin/news?app_update=true")
    refute_receive {:store_request, "POST", _}
    assert has_element?(stores, "#store-android", "Not checked yet")

    assert has_element?(
             stores,
             "#store-android",
             "don't refresh while an Android build is being submitted"
           )

    assert has_element?(
             news,
             "#store-hint-android",
             "don't refresh while an Android build is being submitted"
           )

    stores |> element("#refresh-android") |> render_click()
    await_check()
    assert_receive {:store_request, "POST", "/token"}
    assert Cache.snapshot()["android"].data.live.version == "3.2.4"
    assert has_element?(stores, "#store-android", "Checked 0 min ago")
    drain_requests()

    news |> element("#store-hint-android button") |> render_click()
    await_check()
    assert_receive {:store_request, "POST", "/token"}
    assert has_element?(news, "#store-hint-android", "Live for players now: 3.2.4")
    drain_requests()

    Application.put_env(:pidro_server, Cache, play_auto_refresh: true)
    send(Process.whereis(Cache), :refresh)
    await_check()
    assert_receive {:store_request, "POST", "/token"}
  end

  defp drain_requests do
    receive do
      {:store_request, _, _} -> drain_requests()
    after
      0 -> :ok
    end
  end

  defp await_check do
    receive do
      {:store_builds, stores} ->
        if Enum.all?(stores, fn {_, s} -> !s.refreshing end), do: stores, else: await_check()
    after
      5_000 -> flunk("Store refresh did not complete")
    end
  end
end
