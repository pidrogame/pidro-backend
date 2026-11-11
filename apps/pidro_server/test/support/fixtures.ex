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

defmodule PidroServer.ClassicPremiumFixtures do
  @moduledoc """
  Stand-ins for Classic's lookup by id and for RevenueCat (PID-391), on
  `Req.Test`. Each reports what it was asked to the test process.
  """

  alias PidroServer.Accounts.ClassicClient
  alias PidroServer.RevenueCat

  @doc """
  Classic answers every lookup with `premium.until` = `until` (an ISO 8601
  string or nil), or with `status` when given as `{:status, code}`.
  """
  def stub_classic(until, test \\ self()) do
    Req.Test.stub(ClassicClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:classic_lookup, conn.query_params})

      case until do
        {:status, status} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "x"})

        until ->
          Req.Test.json(conn, %{
            "classic" => %{
              "id" => String.to_integer(conn.query_params["id"]),
              "premium" => %{
                "active" => until != nil,
                "until" => until,
                "product" => until && "pidro.premium.yearly"
              }
            }
          })
      end
    end)
  end

  @doc """
  A RevenueCat that remembers the latest promotional grant and reports it on
  the next subscriber read, or answers `{:status, code}` to a grant.
  """
  def fake_revenuecat(grant_answer \\ :ok, test \\ self()) do
    {:ok, granted} = Agent.start_link(fn -> nil end)

    Req.Test.stub(RevenueCat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.method, grant_answer} do
        {"POST", {:status, status}} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{})

        {"POST", :ok} ->
          end_time_ms = Jason.decode!(body)["end_time_ms"]
          Agent.update(granted, fn _ -> end_time_ms end)
          send(test, {:revenuecat_grant, conn.request_path, end_time_ms})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

        {"GET", _} ->
          send(test, {:revenuecat_read, conn.request_path})
          Req.Test.json(conn, subscriber(Agent.get(granted, & &1)))
      end
    end)
  end

  defp subscriber(nil), do: %{"subscriber" => %{"entitlements" => %{}, "subscriptions" => %{}}}

  defp subscriber(end_time_ms) do
    expires = end_time_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    %{
      "subscriber" => %{
        "original_app_user_id" => "$RCAnonymousID:test",
        "entitlements" => %{
          "premium" => %{"expires_date" => expires, "product_identifier" => "rc_promo_premium"}
        },
        "subscriptions" => %{
          "rc_promo_premium" => %{"expires_date" => expires, "store" => "promotional"}
        }
      }
    }
  end

  @doc "The time `days` from now, to the second."
  def days_from_now(days),
    do: DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
end
