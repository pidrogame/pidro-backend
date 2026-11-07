defmodule PidroServer.EntitlementsTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.AccountsFixtures
  alias PidroServer.Entitlements
  alias PidroServer.Entitlements.Entitlement

  defp entitlement(user, attrs) do
    Repo.insert!(
      struct(
        %Entitlement{user_id: user.id, entitlement: "premium", active: true, source: "store"},
        attrs
      )
    )
  end

  defp from_now(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

  describe "premium?/1" do
    test "an active row that runs into the future or never ends is Premium" do
      dated = AccountsFixtures.user_fixture()
      lifetime = AccountsFixtures.user_fixture()
      entitlement(dated, expires_at: from_now(3_600))
      entitlement(lifetime, expires_at: nil)

      assert Entitlements.premium?(dated)
      assert Entitlements.premium?(lifetime.id)
    end

    test "no row, an inactive row or a past expiry is not Premium" do
      nobody = AccountsFixtures.user_fixture()
      inactive = AccountsFixtures.user_fixture()
      lapsed = AccountsFixtures.user_fixture()
      entitlement(inactive, active: false, expires_at: from_now(3_600))
      entitlement(lapsed, expires_at: from_now(-60))

      refute Entitlements.premium?(nobody)
      refute Entitlements.premium?(inactive)
      refute Entitlements.premium?(lapsed)
    end

    test "another entitlement name is not Premium" do
      user = AccountsFixtures.user_fixture()
      entitlement(user, entitlement: "founders", expires_at: nil)

      refute Entitlements.premium?(user)
    end
  end

  defp fixture(name),
    do: File.read!(Path.expand("../fixtures/revenuecat/#{name}.json", __DIR__)) |> Jason.decode!()

  defp stub_subscriber(name) do
    test = self()

    Req.Test.stub(PidroServer.RevenueCat, fn conn ->
      send(
        test,
        {:revenuecat, conn.method, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      Req.Test.json(conn, fixture(name))
    end)
  end

  describe "sync_from_revenuecat/1" do
    test "an active App Store subscription writes an active row with its product and store" do
      user = AccountsFixtures.user_fixture()
      stub_subscriber("active")

      assert {:ok, row} = Entitlements.sync_from_revenuecat(user.id)

      assert_received {:revenuecat, "GET", path, ["Bearer revenuecat-test-key"]}
      assert path == "/v1/subscribers/#{user.id}"

      assert %Entitlement{
               user_id: user_id,
               entitlement: "premium",
               active: true,
               expires_at: ~U[2099-11-07 10:00:00Z],
               product_id: "pidro.yearauto",
               store: "app_store",
               source: "store",
               rc_original_app_user_id: "$RCAnonymousID:8f3c1e0a2b4d4c6e9a1b3c5d7e9f0a1b"
             } = row

      assert user_id == user.id
      assert %DateTime{} = row.last_synced_at
      assert Entitlements.premium?(user)
    end

    test "an expired subscription keeps its row but turns it inactive" do
      user = AccountsFixtures.user_fixture()
      stub_subscriber("expired")

      assert {:ok, %Entitlement{active: false, store: "play_store"} = row} =
               Entitlements.sync_from_revenuecat(user.id)

      assert row.expires_at == ~U[2026-10-01 09:00:00Z]
      assert row.product_id == "pidro.onemonthsubscription"
      refute Entitlements.premium?(user)
    end

    test "no expiry is lifetime" do
      user = AccountsFixtures.user_fixture()
      stub_subscriber("lifetime")

      assert {:ok,
              %Entitlement{
                active: true,
                expires_at: nil,
                product_id: "pidro.lifetime",
                store: "app_store"
              }} = Entitlements.sync_from_revenuecat(user.id)

      assert Entitlements.premium?(user)
    end

    test "no premium entitlement creates no row" do
      user = AccountsFixtures.user_fixture()
      stub_subscriber("no_entitlement")

      assert Entitlements.sync_from_revenuecat(user.id) == {:ok, nil}
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "no premium entitlement turns an existing row inactive and leaves its dates" do
      user = AccountsFixtures.user_fixture()
      entitlement(user, expires_at: from_now(86_400), product_id: "pidro.yearauto")
      stub_subscriber("no_entitlement")

      assert {:ok, %Entitlement{active: false, product_id: "pidro.yearauto"}} =
               Entitlements.sync_from_revenuecat(user.id)

      refute Entitlements.premium?(user)
      assert Repo.aggregate(Entitlement, :count) == 1
    end

    test "a second sync updates the same row" do
      user = AccountsFixtures.user_fixture()
      stub_subscriber("active")
      {:ok, first} = Entitlements.sync_from_revenuecat(user.id)
      stub_subscriber("expired")

      assert {:ok, second} = Entitlements.sync_from_revenuecat(user.id)
      assert second.id == first.id
      assert {second.active, second.store} == {false, "play_store"}
      assert second.source == "store"
    end

    test "an id that is not one of our players never reaches RevenueCat" do
      stub_subscriber("active")

      assert Entitlements.sync_from_revenuecat(Ecto.UUID.generate()) == {:error, :not_a_user}
      assert Entitlements.sync_from_revenuecat("1137091") == {:error, :not_a_user}
      refute_received {:revenuecat, _, _, _}
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "a 201 from RevenueCat, which created the customer, is a success" do
      user = AccountsFixtures.user_fixture()

      Req.Test.stub(PidroServer.RevenueCat, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(fixture("active"))
      end)

      assert {:ok, %Entitlement{active: true}} = Entitlements.sync_from_revenuecat(user.id)
    end

    test "an upper-case id reaches RevenueCat in its canonical lower-case form" do
      user = AccountsFixtures.user_fixture()
      stub_subscriber("active")

      assert {:ok, %Entitlement{user_id: user_id}} =
               Entitlements.sync_from_revenuecat(String.upcase(user.id))

      assert user_id == user.id
      assert_received {:revenuecat, "GET", path, _auth}
      assert path == "/v1/subscribers/#{user.id}"
    end

    test "a RevenueCat failure writes nothing and says so" do
      user = AccountsFixtures.user_fixture()
      Req.Test.stub(PidroServer.RevenueCat, &Plug.Conn.send_resp(&1, 500, "oops"))

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn -> Entitlements.sync_from_revenuecat(user.id) end)

      assert result == {:error, {:revenuecat_status, 500}}
      assert Repo.aggregate(Entitlement, :count) == 0
    end
  end

  describe "grant_promotional/3" do
    test "grants through RevenueCat, syncs back and records why" do
      user = AccountsFixtures.user_fixture()
      test = self()

      Req.Test.stub(PidroServer.RevenueCat, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:revenuecat, conn.method, conn.request_path, body})

        case conn.method do
          "POST" -> Req.Test.json(conn, fixture("promotional"))
          "GET" -> Req.Test.json(conn, fixture("promotional"))
        end
      end)

      assert {:ok, row} =
               Entitlements.grant_promotional(
                 user.id,
                 ~U[2099-06-30 00:00:00Z],
                 "classic_honored"
               )

      assert_received {:revenuecat, "POST", path, body}
      assert path == "/v1/subscribers/#{user.id}/entitlements/premium/promotional"
      assert Jason.decode!(body) == %{"end_time_ms" => 4_086_460_800_000}
      assert_received {:revenuecat, "GET", _path, _body}

      assert %Entitlement{
               active: true,
               expires_at: ~U[2099-06-30 00:00:00Z],
               store: "promotional",
               source: "classic_honored"
             } = row

      assert Entitlements.premium_fields(user) == %{
               premium: true,
               premium_until: ~U[2099-06-30 00:00:00Z],
               premium_source: "classic_honored"
             }

      # A later sync keeps the reason it was granted for.
      assert {:ok, %Entitlement{source: "classic_honored"}} =
               Entitlements.sync_from_revenuecat(user.id)
    end

    test "RevenueCat answering the grant with 201 is a success" do
      user = AccountsFixtures.user_fixture()

      Req.Test.stub(PidroServer.RevenueCat, fn conn ->
        status = if conn.method == "POST", do: 201, else: 200
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(fixture("promotional"))
      end)

      assert {:ok, %Entitlement{source: "promotional", active: true}} =
               Entitlements.grant_promotional(user.id, ~U[2099-06-30 00:00:00Z], "promotional")
    end

    test "a grant over a longer store subscription keeps the row a store purchase" do
      user = AccountsFixtures.user_fixture()

      Req.Test.stub(PidroServer.RevenueCat, fn conn ->
        Req.Test.json(conn, fixture("active"))
      end)

      assert {:ok, %Entitlement{store: "app_store", source: "store"}} =
               Entitlements.grant_promotional(
                 user.id,
                 ~U[2099-06-30 00:00:00Z],
                 "classic_honored"
               )
    end

    test "a refused grant writes nothing" do
      user = AccountsFixtures.user_fixture()
      Req.Test.stub(PidroServer.RevenueCat, &Plug.Conn.send_resp(&1, 400, "{}"))

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Entitlements.grant_promotional(user.id, ~U[2099-06-30 00:00:00Z], "promotional")
        end)

      assert result == {:error, {:revenuecat_status, 400}}
      assert Entitlements.get(user.id) == nil
    end
  end

  test "premium_fields/1 without Premium is false and nil" do
    user = AccountsFixtures.user_fixture()
    entitlement(user, expires_at: from_now(-60))

    assert Entitlements.premium_fields(user) ==
             %{premium: false, premium_until: nil, premium_source: nil}
  end
end
