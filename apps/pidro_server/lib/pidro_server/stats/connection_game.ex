defmodule PidroServer.Stats.ConnectionGame do
  @moduledoc "One player's aggregate connection measurements for one game; no raw probe log."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "connection_games" do
    field :user_id, :string
    field :room_id, :string
    field :room_code, :string
    field :game_instance_id, :string
    field :checks_sent, :integer
    field :unanswered_checks, :integer
    field :median_ms, :float
    field :p95_ms, :float
    field :rtt_histogram, :map, default: %{}
    field :drops, :integer
    field :disconnected_seconds, :float
    field :duration_seconds, :float
    field :app_version, :string
    field :platform, :string
    field :network, :string
    field :network_ms, :map, default: %{}
    timestamps()
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([
      :user_id,
      :room_id,
      :room_code,
      :game_instance_id,
      :checks_sent,
      :unanswered_checks,
      :drops,
      :disconnected_seconds,
      :duration_seconds
    ])
    |> validate_number(:checks_sent, greater_than_or_equal_to: 0)
    |> validate_number(:unanswered_checks, greater_than_or_equal_to: 0)
    |> validate_number(:drops, greater_than_or_equal_to: 0)
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:disconnected_seconds, greater_than_or_equal_to: 0)
    |> validate_inclusion(:network, ~w(wifi cellular none unknown))
    |> unique_constraint([:user_id, :game_instance_id])
  end
end
