defmodule PidroServer.BotCatalogue do
  @moduledoc "Admin-owned bot profiles with a node-local public/allocation snapshot."
  use GenServer
  import Ecto.Query
  alias PidroServer.BotCatalogue.Profile
  alias PidroServer.Games.Bots.Strategies.{RandomStrategy, RulebookStrategy}
  alias PidroServer.Repo

  @topic "bot_catalogue"
  @legacy ~w(marcel antti jocke)
  # How long a character thinks over a move, against the lifecycle's bot delay.
  @tempo_factors %{"quick" => 0.75, "steady" => 1.0, "slow" => 1.3}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(PidroServer.PubSub, @topic)
    load_snapshot()
    {:ok, nil}
  end

  @impl true
  def handle_info(:bot_catalogue_changed, state) do
    load_snapshot()
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    profiles = load_snapshot()
    Phoenix.PubSub.broadcast_from(PidroServer.PubSub, self(), @topic, :bot_catalogue_changed)
    {:reply, profiles, state}
  end

  def defaults do
    Enum.map(@legacy, &%Profile{id: &1, name: String.capitalize(&1), portrait: &1})
  end

  def list do
    Repo.all(
      from p in Profile,
        order_by: [asc: p.inserted_at, asc: p.id],
        select:
          struct(p, [
            :id,
            :name,
            :description,
            :enabled,
            :strategy,
            :tempo,
            :portrait,
            :image_version,
            :inserted_at,
            :updated_at
          ])
    )
  end

  def get!(id), do: Repo.get!(Profile, id)
  def change(profile, attrs \\ %{}), do: Profile.changeset(profile, attrs)

  def save(profile, attrs, upload \\ nil) do
    with {:ok, changeset} <- prepare_image(change(profile, attrs), upload),
         {:ok, profile} <- Repo.insert_or_update(validate_portrait(changeset)) do
      refresh()
      {:ok, profile}
    end
  end

  def new, do: %Profile{id: Ecto.UUID.generate()}

  def refresh, do: GenServer.call(__MODULE__, :refresh)

  defp load_snapshot do
    profiles = list()
    :persistent_term.put(__MODULE__, profiles)
    profiles
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :undefined_table do
        :persistent_term.put(__MODULE__, defaults())
        defaults()
      else
        reraise error, __STACKTRACE__
      end
  end

  def profiles, do: :persistent_term.get(__MODULE__, defaults())

  def available do
    case Enum.filter(profiles(), & &1.enabled) do
      [] ->
        defaults()

      enabled ->
        # Keep the original shuffle input stable for legacy seeded rooms.
        Enum.sort_by(enabled, fn profile ->
          Enum.find_index(@legacy, &(&1 == profile.id)) || length(@legacy)
        end)
    end
  end

  def profile(id), do: Enum.find(profiles() ++ defaults(), &(&1.id == id))

  def public(profile) do
    Map.take(profile, [:id, :name, :description, :tempo])
    |> Map.put(:avatar_url, avatar_url(profile))
  end

  def avatar_url(%{portrait: "upload", id: id, image_version: version}),
    do: PidroServerWeb.Endpoint.url() <> "/api/v1/bots/#{id}/avatar/#{version}"

  def avatar_url(%{portrait: portrait}),
    do: PidroServerWeb.Endpoint.url() <> "/images/bots/#{portrait}.svg"

  def strategy("random"), do: RandomStrategy
  def strategy(_), do: RulebookStrategy

  @doc "The factor on the room's bot beat for a persona's tempo; without one a bot is steady."
  def tempo_factor(persona) do
    case profile(persona) do
      %{tempo: tempo} -> Map.get(@tempo_factors, tempo, 1.0)
      _ -> 1.0
    end
  end

  def fetch_image(id, version) do
    Repo.one(
      from p in Profile, where: p.id == ^id and p.image_version == ^version, select: p.image
    )
  end

  defp validate_portrait(changeset) do
    if Ecto.Changeset.get_field(changeset, :portrait) == "upload" and
         is_nil(Ecto.Changeset.get_field(changeset, :image_version)) do
      Ecto.Changeset.add_error(changeset, :portrait, "upload an image first")
    else
      changeset
    end
  end

  defp prepare_image(changeset, nil), do: {:ok, changeset}

  defp prepare_image(changeset, %Plug.Upload{} = upload) do
    case PidroServer.Accounts.Avatars.normalize_upload(upload) do
      {:ok, jpeg} ->
        version = :crypto.hash(:sha256, jpeg) |> Base.encode16(case: :lower)

        changeset =
          changeset
          |> Ecto.Changeset.put_change(:image, jpeg)
          |> Ecto.Changeset.put_change(:image_version, version)

        {:ok, changeset}

      error ->
        error
    end
  end
end
