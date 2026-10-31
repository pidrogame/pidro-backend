defmodule PidroServer.Stats.SeatEvent do
  @moduledoc """
  One thing that happened to a player's seat at a live table, for the beta
  report. Kinds:

    * `drop` - the player's connection went and the reconnect grace began
    * `return` - the player took the seat back inside the grace period
    * `turn` - the player acted on a timed turn; `elapsed_ms` is how long it took
    * `timeout` - the turn clock ran out and the server played for them
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(drop return turn timeout)

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "seat_events" do
    field :user_id, :string
    field :room_code, :string
    field :kind, :string
    field :elapsed_ms, :integer

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :room_code, :kind, :elapsed_ms])
    |> validate_required([:user_id, :room_code, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:elapsed_ms, greater_than_or_equal_to: 0)
  end
end
