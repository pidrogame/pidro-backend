defmodule PidroServer.Feedback.Entry do
  @moduledoc """
  One row of player feedback: a `note` written in the app, a one-tap
  `pace` or `old_pidro` answer, or a `report` about another player. The id
  is the ticket number.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PidroServer.Accounts.User
  alias PidroServer.Mailer

  @answers %{
    "pace" => ~w(too_slow right too_fast skipped),
    "old_pidro" => ~w(worse same better skipped)
  }
  @detail_keys ~w(app_version native_build update_id channel platform os_version device_model)
  @email_format ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/

  @type t :: %__MODULE__{}

  schema "feedback" do
    field :kind, :string
    field :body, :string
    field :answer, :string
    field :reply_email, :string
    field :game_id, :binary_id
    field :rule_set, :string
    field :details, :map, default: %{}
    field :status, :string, default: "open"
    belongs_to :user, User, type: :binary_id
    belongs_to :reported_user, User, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts what the app sends for `kind`; the server sets user, game and rule
  set. A note without a reply address takes `account_email`; an answer needs
  a player.
  """
  def changeset(entry, params, account_email) do
    entry
    |> cast(params, [:kind])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, ["note" | Map.keys(@answers)])
    |> cast_kind(params, account_email)
  end

  @doc """
  A report the server builds: the reason in `answer`, the reported
  player's lines in `body`, the game in `details`. Never cast from a client.
  """
  def report_changeset(entry, reason) do
    entry
    |> change(kind: "report", answer: reason)
    |> validate_inclusion(:answer, ~w(rude bothering other))
    |> validate_required([:reported_user_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:reported_user_id)
    |> unique_constraint([:user_id, :reported_user_id],
      name: :feedback_one_report_per_game,
      message: "already reported"
    )
  end

  @doc "Marks an entry `open` or `done`."
  def status_changeset(entry, status) do
    entry |> change(status: status) |> validate_inclusion(:status, ~w(open done))
  end

  defp cast_kind(%{changes: %{kind: "note"}} = changeset, params, account_email) do
    changeset
    |> cast(params, [:body, :reply_email, :details])
    |> validate_required([:body])
    |> validate_length(:body, max: 5_000)
    |> validate_length(:reply_email, max: 160)
    |> validate_change(:reply_email, fn :reply_email, email ->
      if email =~ @email_format and Mailer.sendable?(email),
        do: [],
        else: [reply_email: "must be a valid email address"]
    end)
    |> update_change(:details, &details/1)
    |> then(
      &if get_field(&1, :reply_email), do: &1, else: put_change(&1, :reply_email, account_email)
    )
  end

  defp cast_kind(%{changes: %{kind: kind}} = changeset, params, _account_email)
       when is_map_key(@answers, kind) do
    changeset
    |> cast(params, [:answer])
    |> validate_required([:answer])
    |> validate_inclusion(:answer, @answers[kind])
    |> validate_required([:user_id], message: "must be signed in")
  end

  defp cast_kind(changeset, _params, _account_email), do: changeset

  # Only the known device fields, as short strings.
  defp details(nil), do: %{}

  defp details(details) do
    for {key, value} <- Map.take(details, @detail_keys), is_binary(value), into: %{} do
      {key, String.slice(value, 0, 100)}
    end
  end
end
