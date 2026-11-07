defmodule PidroServer.Entitlements.RevenueCatEvent do
  @moduledoc """
  A RevenueCat webhook event as it arrived, stored once per `event_id`.
  `processed_at` is set once its sync succeeded; `error` says what went wrong
  or which ids were skipped.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "revenuecat_events" do
    field :event_id, :string
    field :type, :string
    field :app_user_id, :string
    field :payload, :map
    field :processed_at, :utc_datetime
    field :error, :string

    timestamps(type: :utc_datetime)
  end
end
