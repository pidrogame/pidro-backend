defmodule PidroServer.PremiumUnconfiguredTest do
  # Not async: it swaps the RevenueCat config for the whole node.
  use PidroServer.DataCase, async: false

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
end
