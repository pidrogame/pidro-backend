defmodule PidroServer.Repo.Migrations.AddAppleRefreshTokens do
  use Ecto.Migration

  # PID-158: the encrypted Sign in with Apple refresh token, revoked when the
  # account is deleted. A claim ticket carries it until the claim links the identity.
  def change do
    alter table(:user_identities) do
      add :apple_refresh_token, :text
      add :apple_client_id, :string
    end

    alter table(:classic_claim_tickets) do
      add :provider_apple_refresh_token, :text
    end
  end
end
