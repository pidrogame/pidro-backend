defmodule PidroServer.Release do
  @moduledoc """
  Release tasks for production deployments.

  Used for running migrations and other maintenance tasks in production
  where Mix is not available.

  ## Usage

  Run migrations:

      ./bin/pidro_server eval "PidroServer.Release.migrate()"

  Rollback migrations:

      ./bin/pidro_server eval "PidroServer.Release.rollback(PidroServer.Repo, 20231101120000)"
  """

  @app :pidro_server

  @doc """
  Runs all pending migrations.

  This function loads the application, retrieves all configured Ecto repos,
  and runs any pending migrations for each repo.

  ## Examples

      iex> PidroServer.Release.migrate()
      :ok
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls back migrations to a specific version.

  ## Parameters

    * `repo` - The Ecto repository module
    * `version` - The migration version to rollback to (integer or string)

  ## Examples

      iex> PidroServer.Release.rollback(PidroServer.Repo, 20231101120000)
      :ok
  """
  @spec rollback(module(), integer() | String.t()) :: :ok
  def rollback(repo, version) do
    load_app()

    version =
      case version do
        v when is_binary(v) -> String.to_integer(v)
        v when is_integer(v) -> v
      end

    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @doc """
  Drops the database.

  **WARNING**: This will delete all data. Use with extreme caution!

  ## Examples

      iex> PidroServer.Release.drop()
      :ok
  """
  @spec drop() :: :ok
  def drop do
    load_app()

    for repo <- repos() do
      repo.__adapter__().storage_down(repo.config())
    end

    :ok
  end

  @doc """
  Creates the database.

  ## Examples

      iex> PidroServer.Release.create()
      :ok
  """
  @spec create() :: :ok
  def create do
    load_app()

    for repo <- repos() do
      repo.__adapter__().storage_up(repo.config())
    end

    :ok
  end

  @doc """
  Seeds the database with initial data.

  This function runs the seeds script located at priv/repo/seeds.exs.

  ## Examples

      iex> PidroServer.Release.seed()
      :ok
  """
  @spec seed() :: :ok
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seeds_path = Application.app_dir(@app, "priv/repo/seeds.exs")

          if File.exists?(seeds_path) do
            Code.eval_file(seeds_path)
          end

          :ok
        end)
    end

    :ok
  end

  @doc """
  Imports the fixed Classic name snapshot (PID-142) from a JSON file inside
  the container. Safe to re-run: existing reservations are never changed.

      ./bin/pidro_server eval 'PidroServer.Release.import_classic_name_reservations("/tmp/classic-names.json")'
  """
  @spec import_classic_name_reservations(Path.t()) :: :ok
  def import_classic_name_reservations(path) do
    load_app()

    {:ok, summary, _started_apps} =
      Ecto.Migrator.with_repo(PidroServer.Repo, fn _repo ->
        path
        |> PidroServer.Accounts.ClassicNameReservations.import_file()
        |> PidroServer.Accounts.ClassicNameReservations.import_summary()
      end)

    IO.puts(summary)
    :ok
  end

  @doc """
  Queues every claimed Classic subscriber without a carry-over row for the
  Classic Premium retry job (PID-391) and prints how many. Safe to re-run.

      ./bin/pidro_server eval "PidroServer.Release.queue_classic_premium()"
  """
  @spec queue_classic_premium() :: :ok
  def queue_classic_premium do
    load_app()

    {:ok, count, _started_apps} =
      Ecto.Migrator.with_repo(PidroServer.Repo, fn _repo ->
        PidroServer.ClassicPremium.queue_claimed()
      end)

    IO.puts("Queued #{count} Classic subscriber(s) for the Premium carry-over.")
    :ok
  end

  @doc """
  Creates the first ops-panel admin from `ADMIN_EMAIL`, if no admin exists.

  Invoke after production migrations with `just seed-admin`, which runs:

      ./bin/pidro_server eval "PidroServer.Release.seed_admin()"
  """
  @spec seed_admin() :: :ok
  def seed_admin do
    load_app()

    {:ok, result, _started_apps} =
      Ecto.Migrator.with_repo(PidroServer.Repo, fn _repo ->
        PidroServer.Admins.seed_first_admin()
      end)

    case result do
      {:ok, :already_seeded} ->
        IO.puts("An admin already exists; no changes made.")

      {:ok, admin, temporary_password} ->
        IO.puts("Created #{admin.email}.")
        IO.puts("Temporary password (shown once): #{temporary_password}")
        IO.puts("Change it immediately at first login.")

      {:error, :admin_seed_email_missing} ->
        raise "Set ADMIN_EMAIL before running PidroServer.Release.seed_admin/0."

      {:error, changeset} ->
        raise "Could not create the first admin: #{inspect(changeset.errors)}"
    end

    :ok
  end

  # Private functions

  @spec repos() :: [module()]
  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @spec load_app() :: :ok | {:error, term()}
  defp load_app do
    Application.load(@app)
  end
end
