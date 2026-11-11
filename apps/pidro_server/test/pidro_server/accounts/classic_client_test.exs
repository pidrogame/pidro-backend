defmodule PidroServer.Accounts.ClassicClientTest do
  use ExUnit.Case, async: true

  alias PidroServer.Accounts.ClassicClient

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "uses the restricted Classic password endpoint with the shared bearer secret" do
    Req.Test.expect(ClassicClient, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/internal/claims/verify_password"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer classic-test-secret"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"login" => "old@example.com", "password" => "secret"}
      Req.Test.json(conn, %{"classic" => %{"id" => 99, "username" => "Veteran"}})
    end)

    assert {:ok, %{"id" => 99}} = ClassicClient.verify_password("old@example.com", "secret")
  end

  test "looks up a social identity without accepting a public Classic id" do
    Req.Test.expect(ClassicClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "GET"
      assert conn.request_path == "/internal/claims/lookup"
      assert conn.query_params == %{"fbid" => "old-app-id"}
      Req.Test.json(conn, %{"classic" => %{"id" => 100}})
    end)

    assert {:ok, %{"id" => 100}} = ClassicClient.lookup(:fbid, "old-app-id")
  end

  # The exact payload api.pidro.online returns for /internal/claims/* (pidro_api
  # PidroApi.Claims.profile/1), as seen in production on 2026-09-28.
  @real_classic_profile %{
    "classic" => %{
      "id" => 50,
      "username" => nil,
      "has_username" => false,
      "first_name" => "Bengt",
      "email" => "bengt@example.com",
      "fbid" => nil,
      "member_since" => "2014-03-02T10:00:00",
      "avatar" => %{"picture_index" => 0, "url" => nil},
      "xp" => 0,
      "level" => 1,
      "games" => %{
        "legacy_played_games" => 1862,
        "legacy_victories" => 937,
        "legacy_losses" => 925,
        "total_game" => 0,
        "win_game" => 0,
        "lost_game" => 0,
        "win_percent" => 0,
        "games_logged" => 0,
        "games_started" => 0,
        "games_ended" => 0
      },
      "premium" => %{"active" => false, "until" => nil, "product" => nil},
      "badges" => [],
      "account" => %{"visible" => true, "deleted" => false}
    }
  }

  test "unwraps and flattens the real Classic profile payload" do
    Req.Test.expect(ClassicClient, fn conn -> Req.Test.json(conn, @real_classic_profile) end)

    assert {:ok, profile} = ClassicClient.verify_password("bengt@example.com", "secret")

    assert profile["id"] == 50
    assert profile["username"] == nil
    assert profile["firstname"] == "Bengt"
    assert profile["level"] == 1
    assert profile["played_games"] == 1862
    assert profile["victories"] == 937
    assert profile["losses"] == 925
    assert profile["total_game"] == 0
    assert profile["xpoints_count"] == 0
    assert profile["started"] == 0
    assert profile["ended"] == 0
    assert profile["inserted_at"] == "2014-03-02T10:00:00"
    assert profile["premium_until"] == nil
    assert profile["account_deleted"] == false
    assert profile["account_visible"] == true
  end

  test "lookup unwraps the same payload" do
    Req.Test.expect(ClassicClient, fn conn -> Req.Test.json(conn, @real_classic_profile) end)

    assert {:ok, %{"id" => 50, "firstname" => "Bengt"}} =
             ClassicClient.lookup(:email, "bengt@example.com")
  end

  test "login lookup uses the login query and treats an undeployed lookup as unavailable" do
    Req.Test.expect(ClassicClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"login" => "Bengt"}
      Req.Test.json(conn, @real_classic_profile)
    end)

    assert {:ok, %{"id" => 50}} = ClassicClient.lookup(:login, "Bengt")

    Req.Test.expect(ClassicClient, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad_request"})
    end)

    assert {:error, :provider_unavailable} = ClassicClient.lookup(:login, "Bengt")
  end

  test "looks a linked account up by its Classic id, once, and keeps its premium" do
    profile =
      put_in(@real_classic_profile, ["classic", "premium"], %{
        "active" => true,
        "until" => "2027-03-01T00:00:00Z",
        "product" => "pidro.premium.yearly",
        "store" => %{"name" => "app_store"}
      })

    Req.Test.expect(ClassicClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/internal/claims/lookup"
      assert conn.query_params == %{"id" => "50"}
      Req.Test.json(conn, profile)
    end)

    assert {:ok, found} = ClassicClient.lookup(:id, 50)
    assert found["premium_until"] == "2027-03-01T00:00:00Z"
    assert found["premium_product"] == "pidro.premium.yearly"
    assert found["premium_store"] == %{"name" => "app_store"}

    # Down is one try, not Req's three retries.
    Req.Test.expect(ClassicClient, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
    end)

    assert {:error, :provider_unavailable} = ClassicClient.lookup(:id, 50)
  end

  test "an inactive Classic account is reported as such" do
    Req.Test.expect(ClassicClient, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "account_inactive"})
    end)

    assert {:error, :account_inactive} = ClassicClient.verify_password("old", "secret")
  end

  test "an ambiguous Classic lookup is not accepted as a match" do
    Req.Test.expect(ClassicClient, fn conn ->
      conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error" => "ambiguous"})
    end)

    assert {:error, :ambiguous} = ClassicClient.lookup(:email, "shared@example.com")
  end

  test "a wrong password is invalid credentials" do
    Req.Test.expect(ClassicClient, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_credentials"})
    end)

    assert {:error, :invalid_credentials} = ClassicClient.verify_password("old", "nope")
  end
end
