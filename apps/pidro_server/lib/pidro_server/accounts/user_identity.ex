defmodule PidroServer.Accounts.UserIdentity do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias PidroServer.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_identities" do
    field :provider, Ecto.Enum, values: [:apple, :facebook]
    field :subject, :string
    field :issuer_app, :string
    field :email, :string
    field :email_is_relay, :boolean, default: false
    field :business_ids, {:array, :string}
    field :link_source, Ecto.Enum, values: [:sign_up, :sign_in, :claim, :backfill]
    field :linked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :apple_refresh_token, :string, redact: true
    field :apple_client_id, :string

    belongs_to :user, User
  end

  def link_changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :provider,
      :subject,
      :issuer_app,
      :email,
      :email_is_relay,
      :business_ids,
      :link_source,
      :linked_at,
      :last_used_at,
      :apple_refresh_token,
      :apple_client_id
    ])
    |> validate_required([:provider, :subject, :link_source, :linked_at, :last_used_at])
    |> unique_constraint([:provider, :subject])
  end

  def use_changeset(identity, attrs, used_at) do
    changes =
      [:issuer_app, :email, :business_ids]
      |> Enum.reduce(%{last_used_at: used_at}, fn field, changes ->
        if is_nil(Map.get(identity, field)) and not is_nil(Map.get(attrs, field)) do
          Map.put(changes, field, Map.get(attrs, field))
        else
          changes
        end
      end)
      |> maybe_put_relay(identity, attrs)
      |> maybe_put_apple_token(attrs)

    change(identity, changes)
  end

  # The newest sign-in's refresh token replaces the stored one.
  defp maybe_put_apple_token(changes, %{apple_refresh_token: token, apple_client_id: client_id})
       when is_binary(token),
       do: Map.merge(changes, %{apple_refresh_token: token, apple_client_id: client_id})

  defp maybe_put_apple_token(changes, _attrs), do: changes

  defp maybe_put_relay(changes, %{email: nil}, %{email: email, email_is_relay: relay})
       when is_binary(email),
       do: Map.put(changes, :email_is_relay, relay)

  defp maybe_put_relay(changes, _identity, _attrs), do: changes
end
