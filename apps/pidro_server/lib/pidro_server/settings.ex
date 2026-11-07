defmodule PidroServer.Settings do
  @moduledoc """
  Values an admin changes without a release, one JSON value per key in
  `app_settings`. Read on every use, so a saved change applies on the next
  read and survives restarts and deploys.

  The ad schedule (PID-123) is the first user: `ads/0` reads its five values in
  one query and `put_ads/1` validates and saves them from the admin form.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias PidroServer.Repo

  @type ads :: %{
          ads_enabled: boolean(),
          ads_free_games: non_neg_integer(),
          ads_early_every_n: pos_integer(),
          ads_games_until_steady: non_neg_integer(),
          ads_steady_every_n: pos_integer()
        }

  # Off until the 3.3.0 build that knows about ads is in the stores.
  @ads %{
    ads_enabled: false,
    ads_free_games: 10,
    ads_early_every_n: 3,
    ads_games_until_steady: 40,
    ads_steady_every_n: 2
  }

  @ads_types %{
    ads_enabled: :boolean,
    ads_free_games: :integer,
    ads_early_every_n: :integer,
    ads_games_until_steady: :integer,
    ads_steady_every_n: :integer
  }

  @doc "The stored value for `key`, or `default` when none is stored."
  @spec get(atom() | String.t(), term()) :: term()
  def get(key, default) do
    case Repo.one(from s in "app_settings", where: s.key == ^to_string(key), select: s.value) do
      nil -> default
      value -> value
    end
  end

  @doc "Stores `value` (any JSON value but null) under `key`, replacing any earlier value."
  @spec put(atom() | String.t(), term()) :: :ok
  def put(key, value), do: put_all(%{key => value})

  @doc "The ad schedule's values, each falling back to its default."
  @spec ads() :: ads()
  def ads do
    keys = @ads |> Map.keys() |> Enum.map(&Atom.to_string/1)

    stored =
      Repo.all(
        from s in "app_settings",
          where: s.key in type(^keys, {:array, :string}),
          select: {s.key, s.value}
      )
      |> Map.new()

    # A value of the wrong type, say one put by hand, reads as its default:
    # every /me reads these, old clients included.
    Map.new(@ads, fn {key, default} ->
      case Ecto.Type.cast(@ads_types[key], Map.get(stored, Atom.to_string(key), default)) do
        {:ok, value} when not is_nil(value) -> {key, value}
        _invalid -> {key, default}
      end
    end)
  end

  @doc "A changeset of the ad values over the stored ones, for the admin form."
  @spec change_ads(map()) :: Ecto.Changeset.t()
  def change_ads(attrs \\ %{}) do
    {ads(), @ads_types}
    |> cast(attrs, Map.keys(@ads_types))
    |> validate_required(Map.keys(@ads_types))
    |> validate_number(:ads_free_games, greater_than_or_equal_to: 0)
    |> validate_number(:ads_early_every_n, greater_than_or_equal_to: 1)
    |> validate_number(:ads_games_until_steady, greater_than_or_equal_to: 0)
    |> validate_number(:ads_steady_every_n, greater_than_or_equal_to: 1)
  end

  @doc "Validates and saves the ad values; nothing is saved when one is invalid."
  @spec put_ads(map()) :: {:ok, ads()} | {:error, Ecto.Changeset.t()}
  def put_ads(attrs) do
    with {:ok, ads} <- attrs |> change_ads() |> apply_action(:update) do
      put_all(ads)
      {:ok, ads}
    end
  end

  defp put_all(values) do
    now = DateTime.utc_now()

    rows =
      Enum.map(values, fn {key, value} ->
        %{key: to_string(key), value: value, inserted_at: now, updated_at: now}
      end)

    Repo.insert_all("app_settings", rows,
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    :ok
  end
end
