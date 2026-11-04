defmodule PidroServer.Leagues.Membership do
  @moduledoc "Live points in a room; settlement freezes a separate result."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "league_memberships" do
    field :room_id, :binary_id
    field :user_id, :binary_id
    field :closes_at, :utc_datetime
    field :points, :integer, default: 0
    field :points_at, :utc_datetime_usec
    field :placed_at, :utc_datetime_usec
  end
end
