defmodule PidroServer.PremiumUnconfiguredTest do
  # Not async: it swaps the RevenueCat config for the whole node.
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Entitlements
  alias PidroServer.Entitlements.Entitlement
  alias PidroServer.Repo
  alias PidroServer.RevenueCat

  setup do
    config = Application.fetch_env!(:pidro_server, RevenueCat)
    on_exit(fn -> Application.put_env(:pidro_server, RevenueCat, config) end)
    Application.put_env(:pidro_server, RevenueCat, secret_key: nil, webhook_secret: nil)
  end

  test "nobody is Premium, even with an active row" do
    user = AccountsFixtures.user_fixture()

    Repo.insert!(%Entitlement{
      user_id: user.id,
      entitlement: "premium",
      active: true,
      source: "store"
    })

    refute RevenueCat.configured?()
    refute Entitlements.premium?(user)
  end

  test "the webhook answers 503 and stores nothing" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer revenuecat-test-webhook-secret")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/webhooks/revenuecat",
        Jason.encode!(%{"event" => %{"id" => "e1", "type" => "TEST"}})
      )

    assert response(conn, 503)
    assert Repo.aggregate(PidroServer.Entitlements.RevenueCatEvent, :count) == 0
  end

  test "refresh answers 503 revenuecat_not_configured and /me says not Premium" do
    user = AccountsFixtures.user_fixture()

    authed = fn ->
      put_req_header(build_conn(), "authorization", "Bearer #{Token.generate(user)}")
    end

    assert %{"error_code" => "revenuecat_not_configured"} =
             authed.() |> post(~p"/api/v1/me/entitlements/refresh") |> json_response(503)

    assert %{"premium" => false} =
             authed.()
             |> get(~p"/api/v1/auth/me")
             |> json_response(200)
             |> get_in(["data", "user"])
  end

  test "a Classic Premium carry-over writes nothing and asks nobody" do
    user =
      AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(classic_user_id: 8001, classic_claimed_at: DateTime.utc_now())
      |> Repo.update!()

    # Any call to either would raise: neither has a stub.
    assert PidroServer.ClassicPremium.carry_over(user) == {:ok, nil}
    assert Repo.aggregate(PidroServer.ClassicPremium.Carryover, :count) == 0
    assert Repo.aggregate(Entitlement, :count) == 0
  end

  test "the Classic Premium retry job does nothing" do
    user = AccountsFixtures.user_fixture()

    Repo.insert!(%Entitlement{
      user_id: user.id,
      entitlement: "premium",
      active: true,
      source: "store",
      last_synced_at: ~U[2026-01-01 00:00:00Z]
    })

    assert PidroServer.ClassicPremium.Retry.run_once() == {:ok, %{carried: 0, synced: 0}}
  end
end
