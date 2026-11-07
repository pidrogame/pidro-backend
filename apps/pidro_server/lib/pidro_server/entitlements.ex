defmodule PidroServer.Entitlements do
  @moduledoc """
  Who is Premium (PID-125). The server alone decides, from RevenueCat's
  record of the stores, mirrored into the `entitlements` table.

  This module is the only writer of `entitlements`: nothing else inserts,
  updates or deletes a row, and no date is ever set by hand.
  """

  import Ecto.Query, only: [from: 2]

  alias PidroServer.Entitlements.Entitlement
  alias PidroServer.Repo
  alias PidroServer.RevenueCat

  @premium "premium"

  @doc """
  Whether a player is Premium: an active `premium` row that never ends or ends
  in the future. One query. Without RevenueCat configured nobody is Premium.
  """
  @spec premium?(%{id: Ecto.UUID.t()} | Ecto.UUID.t()) :: boolean()
  def premium?(%{id: user_id}), do: premium?(user_id)

  def premium?(user_id) when is_binary(user_id),
    do: RevenueCat.configured?() and Repo.exists?(active_premium(user_id))

  defp active_premium(user_id) do
    now = DateTime.utc_now()

    from e in Entitlement,
      where:
        e.user_id == ^user_id and e.entitlement == @premium and e.active and
          (is_nil(e.expires_at) or e.expires_at > ^now)
  end
end
