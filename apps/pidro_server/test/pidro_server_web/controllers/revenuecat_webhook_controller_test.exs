defmodule PidroServerWeb.RevenueCatWebhookControllerTest do
  use PidroServerWeb.ConnCase, async: true

  alias PidroServer.AccountsFixtures
  alias PidroServer.Entitlements
  alias PidroServer.Entitlements.RevenueCatEvent
  alias PidroServer.Repo

  @secret "revenuecat-test-webhook-secret"

  defp fixture(name),
    do:
      File.read!(Path.expand("../../fixtures/revenuecat/#{name}.json", __DIR__))
      |> Jason.decode!()

  # Answers GET /v1/subscribers/<id> with the fixture named for that id and
  # reports every id asked for.
  defp stub_subscribers(fixtures) do
    test = self()

    Req.Test.stub(PidroServer.RevenueCat, fn conn ->
      "/v1/subscribers/" <> id = conn.request_path
      send(test, {:synced, id})

      case Map.fetch(fixtures, id) do
        {:ok, name} -> Req.Test.json(conn, fixture(name))
        :error -> Plug.Conn.send_resp(conn, 500, "")
      end
    end)
  end

  defp event(attrs) do
    %{
      "api_version" => "1.0",
      "event" =>
        Map.merge(
          %{
            "id" => Ecto.UUID.generate(),
            "type" => "INITIAL_PURCHASE",
            "event_timestamp_ms" => 1_793_959_200_000,
            "product_id" => "pidro.yearauto",
            "store" => "APP_STORE",
            "environment" => "PRODUCTION"
          },
          attrs
        )
    }
  end

  defp deliver(conn, payload, secret \\ @secret) do
    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhooks/revenuecat", Jason.encode!(payload))
  end

  defp stored(event_id), do: Repo.get_by!(RevenueCatEvent, event_id: event_id)

  test "a purchase is stored, synced and makes the player Premium", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    stub_subscribers(%{user.id => "active"})
    payload = event(%{"app_user_id" => user.id, "original_app_user_id" => user.id})

    assert conn |> deliver(payload) |> response(200)

    assert_received {:synced, id} when id == user.id
    assert Entitlements.premium?(user)
    assert Entitlements.get(user.id).last_event_id == payload["event"]["id"]

    stored = stored(payload["event"]["id"])
    assert stored.type == "INITIAL_PURCHASE"
    assert stored.app_user_id == user.id
    assert stored.payload == payload["event"]
    assert stored.error == nil
    assert %DateTime{} = stored.processed_at
  end

  test "a repeated event answers 200 without syncing again", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    stub_subscribers(%{user.id => "active"})
    payload = event(%{"app_user_id" => user.id})

    assert conn |> deliver(payload) |> response(200)
    assert_received {:synced, _id}

    assert build_conn() |> deliver(payload) |> response(200)
    refute_received {:synced, _id}
    assert Repo.aggregate(RevenueCatEvent, :count) == 1
  end

  test "a wrong, missing or malformed bearer is 401 and stores nothing", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    stub_subscribers(%{user.id => "active"})
    payload = event(%{"app_user_id" => user.id})

    assert conn |> deliver(payload, "wrong") |> response(401)

    for header <- [nil, @secret, "Basic #{@secret}", "Bearer"] do
      conn =
        if header,
          do: put_req_header(build_conn(), "authorization", header),
          else: build_conn()

      assert conn
             |> put_req_header("content-type", "application/json")
             |> post(~p"/webhooks/revenuecat", Jason.encode!(payload))
             |> response(401)
    end

    refute_received {:synced, _id}
    assert Repo.aggregate(RevenueCatEvent, :count) == 0
    refute Entitlements.premium?(user)
  end

  test "a Classic integer id is stored as not a user id and never synced", %{conn: conn} do
    stub_subscribers(%{})
    payload = event(%{"type" => "RENEWAL", "app_user_id" => "1137091"})

    assert conn |> deliver(payload) |> response(200)

    refute_received {:synced, _id}
    stored = stored(payload["event"]["id"])
    assert stored.error == "not a user id"
    assert stored.app_user_id == "1137091"
    assert %DateTime{} = stored.processed_at
  end

  test "an app_user_id that is not a string or number is stored and skipped", %{conn: conn} do
    stub_subscribers(%{})
    payload = event(%{"app_user_id" => %{"nested" => true}})

    assert conn |> deliver(payload) |> response(200)

    refute_received {:synced, _id}
    stored = stored(payload["event"]["id"])
    assert stored.app_user_id == nil
    assert stored.error == "not a user id"
  end

  test "TRANSFER moves Premium from one player to the other", %{conn: conn} do
    from = AccountsFixtures.user_fixture()
    to = AccountsFixtures.user_fixture()

    stub_subscribers(%{from.id => "active"})
    {:ok, _row} = Entitlements.sync_from_revenuecat(from.id)
    assert Entitlements.premium?(from)

    stub_subscribers(%{from.id => "no_entitlement", to.id => "active"})

    payload =
      event(%{
        "type" => "TRANSFER",
        "app_user_id" => to.id,
        "transferred_from" => [from.id, "1137091"],
        "transferred_to" => [to.id]
      })

    assert conn |> deliver(payload) |> response(200)

    assert_received {:synced, id} when id == from.id
    assert_received {:synced, id} when id == to.id
    refute Entitlements.premium?(from)
    assert Entitlements.premium?(to)
    assert stored(payload["event"]["id"]).error == "not a user id"
  end

  test "an unknown type is stored, synced and acknowledged", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    stub_subscribers(%{user.id => "active"})
    payload = event(%{"type" => "SOMETHING_NEW", "app_user_id" => user.id})

    assert conn |> deliver(payload) |> response(200)

    assert_received {:synced, _id}
    assert Entitlements.premium?(user)
    assert %DateTime{} = stored(payload["event"]["id"]).processed_at
  end

  test "a failed sync answers 500, keeps the error and syncs again on retry", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    stub_subscribers(%{})
    payload = event(%{"type" => "RENEWAL", "app_user_id" => user.id})

    {conn, _log} = ExUnit.CaptureLog.with_log(fn -> deliver(conn, payload) end)
    assert response(conn, 500)

    stored = stored(payload["event"]["id"])
    assert stored.processed_at == nil
    assert stored.error =~ "500"

    stub_subscribers(%{user.id => "active"})
    assert build_conn() |> deliver(payload) |> response(200)

    assert_received {:synced, _id}
    assert Entitlements.premium?(user)
    stored = stored(payload["event"]["id"])
    assert %DateTime{} = stored.processed_at
    assert stored.error == nil
  end

  test "an event without an id or type is 400", %{conn: conn} do
    assert conn
           |> deliver(%{"api_version" => "1.0", "event" => %{"type" => "TEST"}})
           |> response(400)

    assert build_conn() |> deliver(%{"nothing" => true}) |> response(400)
    assert Repo.aggregate(RevenueCatEvent, :count) == 0
  end
end
