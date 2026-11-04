defmodule PidroServer.Leagues.Result do
  @moduledoc "A permanent weekly outcome, unaffected by late game saves."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "league_results" do
    field :user_id, :binary_id
    field :week_starts_at, :utc_datetime
    field :week_closes_at, :utc_datetime
    field :old_league, :string
    field :new_league, :string
    field :move, :string
    field :place, :integer
    field :points, :integer
    field :room_size, :integer
    field :seen_at, :utc_datetime_usec
    field :ribbon, :map
  end
end
