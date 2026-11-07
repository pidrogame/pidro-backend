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
end
