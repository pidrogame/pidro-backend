defmodule PidroServer.BotCatalogue.Profile do
  @moduledoc "An independent bot identity, never a user or rating account."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "bot_profiles" do
    field :name, :string
    field :description, :string, default: ""
    field :enabled, :boolean, default: true
    field :strategy, :string, default: "rulebook"
    field :tempo, :string, default: "steady"
    field :portrait, :string, default: "marcel"
    field :image, :binary
    field :image_version, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :description, :enabled, :strategy, :tempo, :portrait],
      empty_values: []
    )
    |> update_change(:name, fn name -> if is_binary(name), do: String.trim(name), else: name end)
    |> update_change(:description, &(&1 || ""))
    |> validate_required([:name, :enabled, :strategy, :tempo, :portrait])
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 500)
    |> validate_inclusion(:strategy, ["rulebook", "random"])
    |> validate_inclusion(:tempo, ~w(quick steady slow))
    |> validate_inclusion(:portrait, ~w(marcel antti jocke upload))
    |> check_constraint(:strategy, name: :supported_strategy)
    |> check_constraint(:tempo, name: :supported_tempo)
  end
end
