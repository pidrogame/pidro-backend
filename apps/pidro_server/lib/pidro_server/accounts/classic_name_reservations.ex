defmodule PidroServer.Accounts.ClassicNameReservations do
  @moduledoc """
  Imports and enforces the fixed snapshot of Classic player names.

  Availability checks are entirely local. A linked Classic owner may use
  their reservation; where multiple Classic accounts share a key, the first
  owner who links while using it keeps it.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias PidroServer.Accounts.{ClassicNameReservation, User}
  alias PidroServer.Repo

  @message "This name belongs to a Classic player. Claim your Classic profile or choose another name."
  @whitespace ~r/\s+/u
  @import_batch_size 5_000

  @doc """
  Returns the fixed reservation key: NFC-normalized, lowercase, trimmed, with
  whitespace collapsed. NFC only merges encodings of the same character; it
  does not fold look-alikes.
  """
  @spec name_key(String.t()) :: String.t()
  def name_key(name) when is_binary(name) do
    name
    |> String.normalize(:nfc)
    |> String.trim()
    |> String.replace(@whitespace, " ")
    |> String.downcase()
  end

  @doc """
  Adds snapshot rows without changing any reservation already recorded for a
  Classic account. Returns import and collision counts.
  """
  def import(rows, imported_at \\ DateTime.utc_now()) when is_list(rows) do
    imported_at = DateTime.truncate(imported_at, :microsecond)
    entries = Enum.map(rows, &import_entry(&1, imported_at))

    inserted =
      entries
      |> Enum.chunk_every(@import_batch_size)
      |> Enum.reduce(0, fn batch, total ->
        {count, _} =
          Repo.insert_all(ClassicNameReservation, batch,
            on_conflict: :nothing,
            conflict_target: [:classic_user_id]
          )

        total + count
      end)

    collisions =
      ClassicNameReservation
      |> group_by([r], r.name_key)
      |> having([r], count(r.classic_user_id) > 1)
      |> select([r], r.name_key)
      |> Repo.all()
      |> length()

    {:ok, %{inserted: inserted, existing: length(entries) - inserted, collisions: collisions}}
  end

  @doc "Reads a JSON array export from `path` and imports it."
  def import_file(path) do
    case path |> File.read!() |> Jason.decode!() do
      rows when is_list(rows) -> __MODULE__.import(rows)
      _other -> raise ArgumentError, "expected a JSON array of Classic accounts"
    end
  end

  @doc "Formats an import result, including the configured ownership cutoff."
  def import_summary({:ok, result}) do
    cutoff = Application.fetch_env!(:pidro_server, __MODULE__)[:cutoff_date]

    "Classic name cutoff #{cutoff}: imported #{result.inserted}, kept #{result.existing} existing, " <>
      "found #{result.collisions} colliding key(s)."
  end

  @doc "Returns whether a name is reserved for a Classic account."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(name) when is_binary(name) do
    key = name_key(name)
    Repo.exists?(from r in ClassicNameReservation, where: r.name_key == ^key)
  end

  @doc "Returns whether a name is reserved for the Classic account `classic_user_id`."
  @spec reserved_for?(String.t(), integer() | nil) :: boolean()
  def reserved_for?(_name, nil), do: false
  def reserved_for?(name, classic_user_id), do: classic_user_id in owner_ids(name_key(name))

  @doc "Adds reservation errors for changed usernames and display names."
  def validate_changes(%Changeset{} = changeset, classic_user_id \\ nil) do
    Enum.reduce([:username, :display_name], changeset, fn field, acc ->
      case Changeset.fetch_change(acc, field) do
        {:ok, name} when is_binary(name) -> validate_name(acc, field, name, classic_user_id)
        _unchanged_or_nil -> acc
      end
    end)
  end

  @doc false
  def lock_claim_names(names) when is_list(names), do: lock_names(names)

  def lock_claim_names(account) when is_map(account) do
    lock_names([fetch(account, :username), fetch(account, :display_name)])
  end

  defp validate_name(changeset, field, name, classic_user_id) do
    key = name_key(name)
    owner_ids = owner_ids(key)

    if owner_ids == [] or allowed_owner?(key, owner_ids, classic_user_id) do
      changeset
    else
      Changeset.add_error(changeset, field, @message, code: :classic_name_reserved)
    end
  end

  defp allowed_owner?(key, owner_ids, classic_user_id) do
    if classic_user_id in owner_ids do
      User
      |> where([u], u.classic_user_id in ^owner_ids and u.classic_user_id != ^classic_user_id)
      |> select([u], {u.username, u.display_name})
      |> Repo.all()
      |> Enum.all?(fn {username, display_name} ->
        name_key(username) != key and (is_nil(display_name) or name_key(display_name) != key)
      end)
    else
      false
    end
  end

  defp owner_ids(key) do
    Repo.all(
      from r in ClassicNameReservation,
        where: r.name_key == ^key,
        select: r.classic_user_id
    )
  end

  defp lock_names(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&name_key/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn key ->
      if Repo.exists?(from r in ClassicNameReservation, where: r.name_key == ^key) do
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "classic-name:#{key}"
        ])
      end
    end)

    :ok
  end

  defp import_entry(row, imported_at) when is_map(row) do
    classic_user_id = fetch(row, :id) || fetch(row, :classic_user_id)
    username = fetch(row, :username)

    unless is_integer(classic_user_id) and is_binary(username) and name_key(username) != "" do
      raise ArgumentError, "each reservation must have an integer id and a non-blank username"
    end

    %{
      classic_user_id: classic_user_id,
      username: username,
      name_key: name_key(username),
      imported_at: imported_at
    }
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
