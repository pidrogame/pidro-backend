defmodule PidroServer.Accounts.ClassicClaimTicket do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias PidroServer.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "classic_claim_tickets" do
    field :token_hash, :binary
    field :classic_user_id, :integer
    field :method, Ecto.Enum, values: [:password, :apple, :facebook]
    field :matched_on, Ecto.Enum, values: [:password, :email, :facebook_id, :facebook_business_id]

    field :provider_id, :string
    field :provider_issuer_app, :string
    field :provider_email, :string
    field :provider_email_is_relay, :boolean, default: false
    field :provider_business_ids, {:array, :string}
    field :provider_apple_refresh_token, :string, redact: true
    field :legacy_data, :map
    field :install_id, :string
    field :expires_at, :utc_datetime_usec
    field :redeemed_at, :utc_datetime_usec

    belongs_to :bound_user, User
    belongs_to :redeemed_by, User

    timestamps(type: :utc_datetime_usec)
  end

  def issue_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :token_hash,
      :classic_user_id,
      :method,
      :matched_on,
      :provider_id,
      :provider_issuer_app,
      :provider_email,
      :provider_email_is_relay,
      :provider_business_ids,
      :provider_apple_refresh_token,
      :legacy_data,
      :bound_user_id,
      :install_id,
      :expires_at
    ])
    |> validate_required([
      :token_hash,
      :classic_user_id,
      :method,
      :matched_on,
      :legacy_data,
      :expires_at
    ])
    |> validate_length(:install_id, max: 64)
    |> validate_binding()
    |> validate_provider()
    |> unique_constraint(:token_hash)
  end

  def redeem_changeset(ticket, user_id, redeemed_at) do
    ticket
    |> change(
      redeemed_by_id: user_id,
      redeemed_at: redeemed_at,
      provider_apple_refresh_token: nil
    )
    |> check_constraint(:redeemed_by_id, name: :claim_ticket_redemption_is_complete)
  end

  defp validate_binding(changeset) do
    case {get_field(changeset, :bound_user_id), get_field(changeset, :install_id)} do
      {user_id, nil} when is_binary(user_id) -> changeset
      {nil, install_id} when is_binary(install_id) and install_id != "" -> changeset
      _ -> add_error(changeset, :binding, "must contain exactly one user or install")
    end
  end

  defp validate_provider(changeset) do
    case {get_field(changeset, :method), get_field(changeset, :provider_id)} do
      {:password, nil} ->
        changeset

      {method, provider_id} when method in [:apple, :facebook] and is_binary(provider_id) ->
        changeset

      _ ->
        add_error(changeset, :provider_id, "must match the verification method")
    end
  end
end
