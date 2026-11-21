defmodule PidroServer.Accounts.FacebookDataDeletion do
  @moduledoc """
  Meta's data-deletion callback for the Facebook app Pidro-2024 (PID-162).

  A verified request deletes the account whose Facebook identity it names with
  `Auth.delete_user/1`. Each request keeps only the confirmation code Meta shows
  the player, when it came and its outcome. Until Classic is retired, every
  request also goes on to Classic's callback.
  """

  use Ecto.Schema
  import Ecto.Query
  require Logger

  alias PidroServer.Accounts.{Auth, ClassicClaimTicket, ProviderIdentity, User, UserIdentity}
  alias PidroServer.Repo

  @primary_key {:code, :string, autogenerate: false}
  schema "facebook_data_deletions" do
    field :outcome, Ecto.Enum, values: [:deleted, :no_account]

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def request(signed_request) do
    with {:ok, subject} <- ProviderIdentity.facebook_signed_request(signed_request),
         {:ok, outcome} <- delete_account(subject) do
      Repo.insert(%__MODULE__{code: new_code(), outcome: outcome})
    end
  end

  def get(code), do: Repo.get(__MODULE__, code)

  # Fire and forget: whatever Classic answers, ours stays the same.
  def forward_to_classic(signed_request) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)

    options =
      Keyword.merge(
        [
          url: Keyword.fetch!(config, :classic_url),
          form: [signed_request: signed_request],
          retry: false,
          receive_timeout: 10_000
        ],
        Keyword.get(config, :req_options, [])
      )

    Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
      case Req.post(options) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.info("Forwarded a Facebook data-deletion request to Classic")

        {:ok, %{status: status}} ->
          Logger.warning(
            "Classic answered #{status} to a forwarded Facebook data-deletion request"
          )

        {:error, error} ->
          Logger.warning(
            "Could not forward a Facebook data-deletion request to Classic: " <>
              Exception.message(error)
          )
      end
    end)
  end

  # An unknown id is an answer too: Meta asks for every player of the app. An
  # unfinished Facebook claim keeps its ticket without an account, so it goes too.
  defp delete_account(subject) do
    Repo.delete_all(
      from t in ClassicClaimTicket, where: t.method == :facebook and t.provider_id == ^subject
    )

    query =
      from u in User,
        join: i in UserIdentity,
        on: i.user_id == u.id,
        where: i.provider == :facebook and i.subject == ^subject

    with %User{} = user <- Repo.one(query),
         {:ok, _deleted} <- Auth.delete_user(user) do
      {:ok, :deleted}
    else
      nil -> {:ok, :no_account}
      {:error, :not_found} -> {:ok, :no_account}
      {:error, reason} -> {:error, reason}
    end
  end

  defp new_code, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
