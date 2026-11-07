defmodule PidroServerWeb.API.UserJSON do
  @moduledoc """
  JSON view module for rendering user data in API responses.

  This module provides functions to serialize user data into JSON format,
  following a JSON:API-like structure with a data wrapper. It handles
  both user-only responses and user-with-token responses.
  """

  @doc """
  Renders a user response, optionally including an authentication token.

  Takes a map with :user and optional :token keys and returns a properly
  formatted JSON response with the user data and token if provided.

  ## Examples

      iex> show(%{user: user, token: "token123"})
      %{data: %{user: user_data, token: "token123"}}

      iex> show(%{user: user})
      %{data: %{user: user_data}}
  """
  def show(%{user: user, token: token} = assigns) do
    data = %{user: user(user), token: token}

    case assigns[:linked_friend] do
      nil -> %{data: data}
      entry -> %{data: Map.put(data, :linked_friend, entry)}
    end
  end

  def show(%{user: user, seat_invitations: invitations}) do
    %{data: %{user: user(user), seat_invitations: invitations}}
  end

  def show(%{user: user}) do
    %{data: %{user: user(user)}}
  end

  @doc """
  Renders a freshly created guest with its token and the invite's state (R10).

  ## Examples

      iex> guest(%{user: user, token: "token123", state: :open})
      %{data: %{user: user_data, token: "token123", state: :open}}
  """
  def guest(%{user: user, token: token, state: state}) do
    %{data: %{user: user(user), token: token, state: state}}
  end

  @doc """
  Renders user data in a data wrapper.

  Takes a map with a :user key and returns the serialized user data
  wrapped in a data envelope.

  ## Examples

      iex> data(%{user: user})
      %{user: user_data}
  """
  def data(%{user: user}) do
    %{user: user(user)}
  end

  @doc false
  # Private function to transform a user struct into a JSON-serializable map.
  #
  # Includes user fields (id, username, email, display_name, share_slug, guest,
  # inserted_at, updated_at) and the Premium fields from
  # PidroServer.Entitlements.premium_fields/1, but explicitly excludes password_hash,
  # token_version, last_seen_at, install_id and guest_creation_token_hash.
  defp user(user) do
    %{
      id: user.id,
      username: user.username,
      email: user.email,
      display_name: user.display_name,
      share_slug: user.share_slug,
      avatar_url: avatar_url(user),
      guest: user.guest,
      age_band: user.age_band,
      terms_version: user.terms_version,
      inserted_at: DateTime.to_iso8601(user.inserted_at),
      updated_at: DateTime.to_iso8601(user.updated_at)
    }
    |> Map.merge(PidroServer.Entitlements.premium_fields(user))
  end

  defp avatar_url(%{avatar_url: url}) when is_binary(url), do: url

  defp avatar_url(user),
    do:
      PidroServer.Accounts.Avatars.url(
        PidroServer.Accounts.Avatars.metadata_for(user.id),
        user.id
      )
end
