defmodule PidroServer.ClassicPremium.Carryover do
  @moduledoc """
  What became of one claimed player's Classic Premium. Only
  `PidroServer.ClassicPremium` writes it. It never holds a store token or
  transaction id: every attempt reads Classic again.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "classic_premium_carryovers" do
    field :user_id, :binary_id
    field :classic_user_id, :integer
    # pending | granted | imported | ended | none
    field :state, :string
    # Classic's own date, never capped.
    field :classic_premium_until, :utc_datetime
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :last_tried_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
