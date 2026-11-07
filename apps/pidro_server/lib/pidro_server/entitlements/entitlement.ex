defmodule PidroServer.Entitlements.Entitlement do
  @moduledoc """
  One player's entitlement as RevenueCat last reported it. Only
  `PidroServer.Entitlements` writes it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "entitlements" do
    field :user_id, :binary_id
    field :entitlement, :string
    field :active, :boolean, default: false
    # nil means it never ends (lifetime).
    field :expires_at, :utc_datetime
    field :product_id, :string
    field :store, :string
    field :source, :string
    field :rc_original_app_user_id, :string
    field :last_event_id, :string
    field :last_synced_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
