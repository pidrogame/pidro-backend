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
    # Where the character is from: it sits first at its own crowd's tables.
    field :home, :string, default: "anywhere"
    # What the character says while thinking, in no app language in particular.
    field :lines, {:array, :string}, default: []
    # How the character talks at the table, and how often (`Games.Bots.Talk`).
    field :voice, :string, default: "dry"
    field :appetite, :string, default: "normal"
    field :image, :binary
    field :image_version, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(
      attrs,
      [
        :name,
        :description,
        :enabled,
        :strategy,
        :tempo,
        :portrait,
        :home,
        :lines,
        :voice,
        :appetite
      ],
      empty_values: []
    )
    |> update_change(:name, fn name -> if is_binary(name), do: String.trim(name), else: name end)
    |> update_change(:description, &(&1 || ""))
    |> update_change(:lines, fn lines ->
      lines |> List.wrap() |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end)
    |> validate_required([
      :name,
      :enabled,
      :strategy,
      :tempo,
      :portrait,
      :home,
      :voice,
      :appetite
    ])
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 500)
    |> validate_length(:lines, max: 8)
    |> validate_change(:lines, fn :lines, lines ->
      if Enum.any?(lines, &(String.length(&1) > 18)),
        do: [lines: "each line should be at most 18 characters"],
        else: []
    end)
    |> validate_inclusion(:strategy, ["rulebook", "random", "search"])
    |> validate_inclusion(:tempo, ~w(quick steady slow))
    |> validate_inclusion(:portrait, ~w(marcel antti jocke upload))
    |> validate_inclusion(:home, ~w(anywhere finland louisiana))
    |> validate_inclusion(:voice, ~w(cheerful warm dry teasing))
    |> validate_inclusion(:appetite, ~w(sparse normal chatty))
    |> check_constraint(:strategy, name: :supported_strategy)
    |> check_constraint(:tempo, name: :supported_tempo)
    |> check_constraint(:home, name: :supported_home)
    |> check_constraint(:voice, name: :supported_voice)
    |> check_constraint(:appetite, name: :supported_appetite)
  end
end
