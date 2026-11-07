defmodule PidroServer.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `PidroServer.Accounts` context.
  """

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Repo

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"

  # The word list reads letters between digits as words, so a suffix can spell
  # one ("user3KYS"); take the next one, as a player would pick another name.
  def unique_username do
    suffix = System.unique_integer([:positive]) |> Integer.to_string(36)
    name = "user#{suffix}"
    if PidroServer.Moderation.allowed?(name), do: name, else: unique_username()
  end

  def valid_user_password, do: "hello world!"

  @doc """
  Registers a user through `Auth.register_user/1`.

  `guest` is not castable from public params, so it is popped from `attrs`
  and, when truthy, applied afterwards through `User.admin_changeset/2`. Every
  other attribute, including an email, reaches the row as given.
  """
  def user_fixture(attrs \\ %{}) do
    {guest, attrs} =
      attrs
      |> Enum.into(%{
        email: unique_user_email(),
        username: unique_username(),
        password: valid_user_password()
      })
      |> Map.pop(:guest)

    {:ok, user} = Auth.register_user(attrs)

    if guest do
      {:ok, user} =
        user
        |> User.admin_changeset(%{guest: true})
        |> Repo.update()

      user
    else
      user
    end
  end

  @doc """
  Creates a guest through `Auth.create_guest_user/2` with an empty taken-name
  list, so the row carries a generated `guest_` username, `guest: true` and no
  credentials.

  `display_name` defaults to a unique short name. `last_seen_at` and
  `inserted_at` are not creation attributes; when given they are stamped on
  the row afterwards, which is how the reaper tests age a guest.
  """
  def guest_fixture(attrs \\ %{}) do
    {stamps, attrs} =
      attrs
      |> Map.new()
      |> Map.split([:last_seen_at, :inserted_at])

    attrs = Map.put_new(attrs, :display_name, "G#{System.unique_integer([:positive])}")
    {:ok, guest} = Auth.create_guest_user(attrs, [])

    if stamps == %{} do
      guest
    else
      guest
      |> Ecto.Changeset.change(stamps)
      |> Repo.update!()
    end
  end
end

defmodule PidroServer.AdminsFixtures do
  @moduledoc false

  alias PidroServer.Admins.Admin
  alias PidroServer.Repo

  def unique_admin_email, do: "admin#{System.unique_integer([:positive])}@example.com"
  def valid_admin_password, do: "valid admin password"

  def admin_fixture(attrs \\ %{}) do
    {force_password_change, attrs} =
      attrs
      |> Enum.into(%{
        email: unique_admin_email(),
        password: valid_admin_password(),
        force_password_change: false
      })
      |> Map.pop(:force_password_change)

    %Admin{}
    |> Admin.registration_changeset(attrs, force_password_change: force_password_change)
    |> Repo.insert!()
  end
end
