defmodule PidroServer.Leagues.Room do
  @moduledoc "One league's weekly room. Closed rooms retain their memberships."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "league_rooms" do
    field :league, :string
    field :starts_at, :utc_datetime
    field :closes_at, :utc_datetime
    field :closed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
