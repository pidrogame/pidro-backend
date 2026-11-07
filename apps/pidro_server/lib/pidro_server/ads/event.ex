defmodule PidroServer.Ads.Event do
  @moduledoc """
  One counted ad moment: `offered` when the server tells an eligible player
  their next solo game needs an ad, `watched` or `unavailable` when the app
  reports how it went, `dismissed` when the player backs out. The user id is
  the only personal data.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "ad_events" do
    field :user_id, :binary_id
    field :kind, :string
    # Set on `offered` only: the solo count the offer was for.
    field :solo_games_started, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
