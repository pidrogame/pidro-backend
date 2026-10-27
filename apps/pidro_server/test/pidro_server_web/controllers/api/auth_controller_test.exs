defmodule PidroServerWeb.API.AuthControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PidroServer.Accounts.{
    Auth,
    ClassicClaims,
    ClassicClaimTicket,
    ClassicNameReservation,
    ClassicNameReservations,
    Token,
    User,
    UserIdentities,
    UserIdentity
  }

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Invites
  alias PidroServer.Invites.Event
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo

  test "a personal link sends the owner a friend request, not a friendship", %{conn: conn} do
    owner = AccountsFixtures.user_fixture(%{display_name: "Bertil"})
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    data =
      conn
      |> post(~p"/api/v1/auth/register", %{
        user: %{username: "sister", email: "sister@example.com", password: "secret123"},
        friend_slug: owner.share_slug,
        age_band: "18_plus",
        terms_version: "1"
      })
      |> json_response(201)
      |> Map.fetch!("data")

    assert_linked_friend(data, owner)
  end

  test "absent, unknown and own slugs leave the normal registration response", %{conn: conn} do
    for {name, slug} <- [{"absent", nil}, {"unknown", "nobody-here"}, {"myself", "myself"}] do
      params = %{user: %{username: name, email: "#{name}@example.com", password: "secret123"}}
      params = if slug, do: Map.put(params, :friend_slug, slug), else: params

      data =
        conn
        |> post(~p"/api/v1/auth/register", params)
        |> json_response(201)
        |> Map.fetch!("data")

      assert Enum.sort(Map.keys(data)) == ["token", "user"]
      assert PidroServer.Friends.list(data["user"]["id"]).friends == []
    end
  end

  test "a guest keeps the slug until upgrade, which sends the owner a request", %{conn: conn} do
    owner = AccountsFixtures.user_fixture()

    guest_data =
      conn
      |> post(~p"/api/v1/auth/guest", %{
        creation_token: Ecto.UUID.generate(),
        friend_slug: owner.share_slug
      })
      |> json_response(201)
      |> Map.fetch!("data")

    refute Map.has_key?(guest_data, "linked_friend")
    assert PidroServer.Friends.list(guest_data["user"]["id"]).friends == []
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    data =
      build_conn()
      |> put_req_header("authorization", "Bearer #{guest_data["token"]}")
      |> post(~p"/api/v1/auth/upgrade", %{
        email: "saved@example.com",
        password: "secret123",
        friend_slug: owner.share_slug,
        age_band: "18_plus",
        terms_version: "1"
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert_linked_friend(data, owner)
  end

  test "a block in either direction silently prevents a link on upgrade", %{conn: conn} do
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    for direction <- [:incoming, :outgoing] do
      owner = AccountsFixtures.user_fixture()
      guest = AccountsFixtures.guest_fixture()
      {a, b} = if direction == :incoming, do: {owner, guest}, else: {guest, owner}
      Repo.insert!(PidroServer.Blocks.Block.changeset(a.id, b.id))

      data =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
        |> post(~p"/api/v1/auth/upgrade", %{
          email: "#{direction}@example.com",
          password: "secret123",
          friend_slug: owner.share_slug
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["user"]["guest"] == false
      refute Map.has_key?(data, "linked_friend")
      assert %{friends: [], requested: []} = PidroServer.Friends.list(guest.id)
      refute_received {:friend_event, _, _, _}
    end
  end

  # A link asks the owner, as a request sent by hand would: it makes no friends.
  defp assert_linked_friend(data, owner) do
    id = data["user"]["id"]
    owner_id = owner.id
    assert %{friends: [], requested: [%{user_id: ^owner_id}]} = PidroServer.Friends.list(id)
    assert %{friends: [], added_you: [%{user_id: ^id}]} = PidroServer.Friends.list(owner_id)

    entry = %{
      user_id: owner_id,
      display_name: owner.display_name || owner.username,
      avatar_url: nil,
      presence: "offline",
      join_as: nil
    }

    newcomer = %{
      user_id: id,
      display_name: data["user"]["display_name"] || data["user"]["username"],
      avatar_url: nil,
      presence: "offline"
    }

    assert data["linked_friend"] == Jason.decode!(Jason.encode!(entry))
    assert_receive {:friends_changed, ^id}
    assert_receive {:friends_changed, ^owner_id}

    assert_receive {:friend_event, ^owner_id, "friend_request",
                    %{player: ^newcomer, played_together_at: nil}}

    refute_received {:friend_event, _, _, _}
  end

  defmodule ErrorMailer do
    use Swoosh.Adapter
    def deliver(_email, _config), do: {:error, :provider_down}
  end

  defmodule RaiseMailer do
    use Swoosh.Adapter
    def deliver(_email, _config), do: raise("smtp exploded")
  end

  defmodule ExitMailer do
    use Swoosh.Adapter
    # Like Swoosh.Adapters.Local without its storage: the exit reason holds the email.
    def deliver(email, _config), do: GenServer.call({:global, :no_mail_storage}, {:push, email})
  end

  defmodule BlockingMailer do
    use Swoosh.Adapter

    # Holds the mail until the test lets it go, then delivers it as the test adapter does.
    def deliver(email, config) do
      [test | _] = Process.get(:"$callers")
      send(test, {:mail_waiting, self()})

      receive do
        :deliver -> Swoosh.Adapters.Test.deliver(email, config)
      end
    end
  end

  defmodule ProviderIdentity do
    def apple("apple-linked"), do: apple_identity("apple-linked-sub", "linked@example.com")
    def apple("apple-classic"), do: apple_identity("apple-classic-sub", "classic@example.com")
    def apple("apple-new"), do: apple_identity("apple-new-sub", "new@example.com")
    def apple("apple-no-email"), do: {:ok, %{"sub" => "apple-no-email-sub"}}
    def apple("apple-down"), do: apple_identity("apple-down-sub", "down@example.com")
    def apple(_token), do: {:error, :invalid_credentials}

    def facebook("facebook-linked"), do: facebook_identity("facebook-linked-id")
    def facebook("facebook-linked-down"), do: facebook_identity("facebook-linked-id")
    def facebook("facebook-classic"), do: facebook_identity("facebook-current-id")

    def facebook("facebook-new"),
      do: facebook_identity("facebook-new-id", "facebook-new@example.com")

    def facebook("facebook-down"), do: facebook_identity("facebook-down-id")
    def facebook(_token), do: {:error, :invalid_credentials}

    def facebook_limited(token, "limited-nonce")
        when token in ["limited-new", "limited-sign-in"] do
      facebook_identity("limited-new-id")
    end

    def facebook_limited("limited-classic", "limited-nonce"),
      do: facebook_identity("limited-classic-id", "classic@example.com")

    def facebook_limited("limited-same-account", "limited-nonce"),
      do: facebook_identity("facebook-new-id", "facebook-new@example.com")

    def facebook_limited(_token, _nonce), do: {:error, :invalid_credentials}

    def facebook_business_ids("facebook-linked"), do: {:ok, ["facebook-linked-old-id"]}
    def facebook_business_ids("facebook-linked-down"), do: {:error, :provider_unavailable}
    def facebook_business_ids("facebook-classic"), do: {:ok, ["facebook-classic-id"]}
    def facebook_business_ids("facebook-new"), do: {:ok, ["facebook-new-old-id"]}
    def facebook_business_ids("facebook-down"), do: {:ok, ["facebook-old-id"]}

    defp apple_identity(subject, email) do
      {:ok,
       %{
         "sub" => subject,
         "aud" => "com.oneapps.pidro",
         "email" => email,
         "email_verified" => true
       }}
    end

    defp facebook_identity(subject, email \\ nil),
      do: {:ok, %{subject: subject, issuer_app: "facebook-app", email: email}}
  end

  defmodule GuestNames do
    def generate, do: {:ok, "Lucky Moose"}
  end

  defmodule RetryGuestNames do
    def generate do
      case Process.get(__MODULE__, 0) do
        0 ->
          Process.put(__MODULE__, 1)
          {:ok, "Lucky Moose"}

        _retried ->
          {:ok, "Brave Badger"}
      end
    end
  end

  describe "register" do
    test "stores a valid top-level declaration and defaults omitted fields", %{conn: conn} do
      declared =
        conn
        |> post(~p"/api/v1/auth/register", %{
          "age_band" => "18_plus",
          "terms_version" => "1",
          "user" => %{
            "username" => "declared_register",
            "email" => "declared-register@example.com",
            "password" => "password123"
          }
        })
        |> json_response(201)
        |> get_in(["data", "user"])

      assert declared["age_band"] == "18_plus"
      assert declared["terms_version"] == "1"
      assert declared["share_slug"] == "declaredregister"
      assert_age_terms(Auth.get_user_by_username("declared_register"), "18_plus", "1")

      omitted =
        build_conn()
        |> post(~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "unknown_register",
            "email" => "unknown-register@example.com",
            "password" => "password123"
          }
        })
        |> json_response(201)
        |> get_in(["data", "user"])

      assert omitted["age_band"] == "unknown"
      assert omitted["terms_version"] == nil
    end

    test "refuses under-13 and invalid declarations before creating a user" do
      for {suffix, declaration, status, code} <- [
            {"under", %{"age_band" => "under_13"}, 403, "AGE_NOT_ELIGIBLE"},
            {"invalid", %{"age_band" => "adult"}, 422, "age_band"}
          ] do
        username = "register_#{suffix}"

        response =
          build_conn()
          |> post(
            ~p"/api/v1/auth/register",
            %{
              "user" => %{
                "username" => username,
                "email" => "#{suffix}@example.com",
                "password" => "password123"
              }
            }
            |> Map.merge(declaration)
          )
          |> json_response(status)

        assert Enum.any?(response["errors"], &(&1["code"] == code))
        refute Auth.get_user_by_username(username)
      end
    end

    test "ignores guest in the request body", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_guest",
            "email" => "register_guest@example.com",
            "password" => "password123",
            "guest" => true
          }
        })

      assert %{"user" => %{"username" => "register_guest", "guest" => false}} =
               json_response(conn, 201)["data"]

      refute Auth.get_user_by_username("register_guest").guest
    end

    test "stores a trimmed display_name", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_named",
            "email" => "register_named@example.com",
            "password" => "password123",
            "display_name" => "  Anna  "
          }
        })

      assert %{"user" => %{"display_name" => "Anna"}} = json_response(conn, 201)["data"]
    end

    test "refuses an address the mailer cannot write as an invalid email", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_comma",
            "email" => "anna,ben@example.com",
            "password" => "password123"
          }
        })

      assert %{
               "errors" => [
                 %{"code" => "email", "detail" => "must be a valid email address"}
               ]
             } = json_response(conn, 422)
    end

    test "rejects a 21-character display_name with a validation error", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_long",
            "email" => "register_long@example.com",
            "password" => "password123",
            "display_name" => String.duplicate("a", 21)
          }
        })

      assert %{"errors" => [%{"code" => "display_name", "detail" => detail}]} =
               json_response(conn, 422)

      assert detail =~ "at most 20"
      assert json_response(conn, 422)["error_code"] == "validation_failed"
      assert json_response(conn, 422)["error_params"] == %{}

      assert json_response(conn, 422)["field_errors"] == [
               %{
                 "field" => "display_name",
                 "error_code" => "field_too_long",
                 "error_params" => %{"count" => 20}
               }
             ]
    end

    test "a reserved public name has the machine-readable reservation code", %{conn: conn} do
      assert {:ok, _} =
               PidroServer.Accounts.ClassicNameReservations.import([
                 %{id: 701, username: "Classic Hero"}
               ])

      response =
        conn
        |> post(~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "newcomer",
            "display_name" => " classic   hero ",
            "email" => "reserved@example.com",
            "password" => "password123"
          }
        })
        |> json_response(422)

      assert %{
               "code" => "classic_name_reserved",
               "title" => "Display name",
               "detail" =>
                 "This name belongs to a Classic player. Claim your Classic profile or choose another name."
             } in response["errors"]

      assert %{
               "field" => "display_name",
               "error_code" => "classic_name_reserved",
               "error_params" => %{}
             } in response["field_errors"]
    end

    test "reservation metadata only overrides its own error code", %{conn: conn} do
      long_name = "Classic Hero Too Long"

      assert {:ok, _} =
               PidroServer.Accounts.ClassicNameReservations.import([
                 %{id: 702, username: long_name}
               ])

      errors =
        conn
        |> post(~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "another_newcomer",
            "display_name" => long_name,
            "email" => "mixed-errors@example.com",
            "password" => "password123"
          }
        })
        |> json_response(422)
        |> Map.fetch!("errors")

      assert Enum.any?(errors, &match?(%{"code" => "classic_name_reserved"}, &1))
      assert Enum.any?(errors, &match?(%{"code" => "display_name"}, &1))
    end
  end

  describe "login" do
    test "fills an unknown declaration and never overwrites a stored band", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "age_login"})

      first =
        conn
        |> post(~p"/api/v1/auth/login", %{
          "username" => user.username,
          "password" => AccountsFixtures.valid_user_password(),
          "age_band" => "13_17",
          "terms_version" => "1"
        })
        |> json_response(200)

      assert get_in(first, ["data", "user", "age_band"]) == "13_17"
      stored = assert_age_terms(Repo.get!(User, user.id), "13_17", "1")

      second =
        build_conn()
        |> post(~p"/api/v1/auth/login", %{
          "username" => user.username,
          "password" => AccountsFixtures.valid_user_password(),
          "age_band" => "18_plus",
          "terms_version" => "2"
        })
        |> json_response(200)

      assert get_in(second, ["data", "user", "age_band"]) == "13_17"
      assert Repo.get!(User, user.id).age_declared_at == stored.age_declared_at
      assert Repo.get!(User, user.id).terms_version == "1"
    end

    test "under-13 and invalid declarations do not change the account" do
      user = AccountsFixtures.user_fixture(%{username: "unchanged_login"})

      for {declaration, status} <- [
            {%{"age_band" => "under_13"}, 403},
            {%{"terms_version" => ""}, 422}
          ] do
        build_conn()
        |> post(
          ~p"/api/v1/auth/login",
          Map.merge(
            %{
              "username" => user.username,
              "password" => AccountsFixtures.valid_user_password()
            },
            declaration
          )
        )
        |> json_response(status)

        assert Repo.get!(User, user.id).age_band == "unknown"
        assert Repo.get!(User, user.id).terms_version == nil
      end
    end

    test "returns invalid credentials for a guest without a password", %{conn: conn} do
      {:ok, guest} =
        %User{}
        |> User.guest_changeset(%{username: "guest_login"})
        |> Repo.insert()

      assert is_nil(guest.password_hash)

      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "username" => "guest_login",
          "password" => "anything"
        })

      assert %{
               "errors" => [
                 %{
                   "code" => "INVALID_CREDENTIALS",
                   "detail" => "Username or password is incorrect"
                 }
               ],
               "error_code" => "invalid_credentials",
               "error_params" => %{}
             } = json_response(conn, 401)
    end
  end

  describe "provider login" do
    setup do
      previous_provider = Application.get_env(:pidro_server, :provider_identity)
      previous_names = Application.get_env(:pidro_server, :guest_names)
      Application.put_env(:pidro_server, :provider_identity, ProviderIdentity)
      Application.put_env(:pidro_server, :guest_names, GuestNames)
      Req.Test.verify_on_exit!()

      on_exit(fn ->
        if previous_provider,
          do: Application.put_env(:pidro_server, :provider_identity, previous_provider),
          else: Application.delete_env(:pidro_server, :provider_identity)

        if previous_names,
          do: Application.put_env(:pidro_server, :guest_names, previous_names),
          else: Application.delete_env(:pidro_server, :guest_names)
      end)
    end

    test "new Apple and Facebook accounts link, but signing in again does not", %{conn: conn} do
      Application.put_env(:pidro_server, :guest_names, RetryGuestNames)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      for {provider, credential} <- [
            {"apple", %{identity_token: "apple-new"}},
            {"facebook", %{access_token: "facebook-new"}}
          ] do
        owner = AccountsFixtures.user_fixture()

        if provider == "apple" do
          expect_classic_not_found(:email, "new@example.com")
        else
          expect_classic_not_found(:fbid, "facebook-new-id")
          expect_classic_not_found(:fbid, "facebook-new-old-id")
          expect_classic_not_found(:email, "facebook-new@example.com")
        end

        params =
          Map.merge(credential, %{
            friend_slug: owner.share_slug,
            age_band: "18_plus",
            terms_version: "1"
          })

        data =
          conn
          |> post("/api/v1/auth/#{provider}", params)
          |> json_response(200)
          |> Map.fetch!("data")

        assert_linked_friend(data, owner)

        assert {:ok, _} = PidroServer.Friends.remove(data["user"]["id"], owner.id)

        signed_in =
          conn
          |> post("/api/v1/auth/#{provider}", params)
          |> json_response(200)
          |> Map.fetch!("data")

        refute Map.has_key?(signed_in, "linked_friend")
        assert %{friends: [], added_you: []} = PidroServer.Friends.list(owner.id)
        refute_received {:friend_event, _, _, _}
      end
    end

    test "Apple returns a linked account without consulting Classic", %{conn: conn} do
      user = provider_user!(:apple_sub, "apple-linked-sub")

      assert %{"user" => %{"id" => user_id}, "token" => token} =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-linked"})
               |> json_response(200)
               |> Map.fetch!("data")

      assert user_id == user.id
      assert is_binary(token)
      assert_token_user(conn, token, user_id)

      identity = Repo.get_by!(UserIdentity, provider: :apple, subject: "apple-linked-sub")
      assert identity.link_source == :backfill
      assert identity.issuer_app == "com.oneapps.pidro"
      assert identity.email == "linked@example.com"
      assert identity.business_ids == []
      assert DateTime.after?(identity.last_used_at, identity.linked_at)
    end

    test "linked provider sign-in fills an unknown band but never overwrites it", %{conn: conn} do
      user = provider_user!(:apple_sub, "apple-linked-sub")

      first =
        conn
        |> post(~p"/api/v1/auth/apple", %{
          identity_token: "apple-linked",
          age_band: "13_17",
          terms_version: "1"
        })
        |> json_response(200)

      assert get_in(first, ["data", "user", "age_band"]) == "13_17"
      assert_age_terms(Repo.get!(User, user.id), "13_17", "1")

      second =
        build_conn()
        |> post(~p"/api/v1/auth/apple", %{
          identity_token: "apple-linked",
          age_band: "18_plus",
          terms_version: "2"
        })
        |> json_response(200)

      assert get_in(second, ["data", "user", "age_band"]) == "13_17"
      assert Repo.get!(User, user.id).terms_version == "1"
    end

    test "Facebook stores a declaration on a newly created provider account", %{conn: conn} do
      expect_classic_not_found(:fbid, "facebook-new-id")
      expect_classic_not_found(:fbid, "facebook-new-old-id")
      expect_classic_not_found(:email, "facebook-new@example.com")

      data =
        conn
        |> post(~p"/api/v1/auth/facebook", %{
          access_token: "facebook-new",
          age_band: "18_plus",
          terms_version: "1"
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["user"]["age_band"] == "18_plus"
      assert_age_terms(Repo.get!(User, data["user"]["id"]), "18_plus", "1")
    end

    test "provider declarations are refused or validated before creating an account", %{
      conn: conn
    } do
      assert %{"errors" => [%{"code" => "AGE_NOT_ELIGIBLE"}]} =
               conn
               |> post(~p"/api/v1/auth/apple", %{
                 identity_token: "apple-new",
                 age_band: "under_13"
               })
               |> json_response(403)

      assert %{"errors" => [%{"code" => "terms_version"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/facebook", %{
                 access_token: "facebook-new",
                 terms_version: String.duplicate("x", 33)
               })
               |> json_response(422)

      refute Repo.get_by(User, apple_sub: "apple-new-sub")
      refute Repo.get_by(User, facebook_id: "facebook-new-id")
    end

    test "Facebook returns a linked account after refreshing business IDs", %{
      conn: conn
    } do
      user = provider_user!(:facebook_id, "facebook-linked-id")

      assert %{"user" => %{"id" => user_id}, "token" => token} =
               conn
               |> post(~p"/api/v1/auth/facebook", %{access_token: "facebook-linked"})
               |> json_response(200)
               |> Map.fetch!("data")

      assert user_id == user.id
      assert is_binary(token)
      assert_token_user(conn, token, user_id)

      identity = Repo.get_by!(UserIdentity, provider: :facebook, subject: "facebook-linked-id")
      assert identity.issuer_app == "facebook-app"
      assert identity.business_ids == ["facebook-linked-old-id"]
    end

    test "Facebook returns a linked account when the optional business-ID lookup fails", %{
      conn: conn
    } do
      user = provider_user!(:facebook_id, "facebook-linked-id")

      data =
        conn
        |> post(~p"/api/v1/auth/facebook", %{access_token: "facebook-linked-down"})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["user"]["id"] == user.id
      assert is_binary(data["token"])

      assert Repo.get_by!(UserIdentity, provider: :facebook, subject: "facebook-linked-id").business_ids ==
               nil
    end

    test "Facebook Limited Login signs up and signs the same subject back in", %{conn: conn} do
      expect_classic_not_found(:fbid, "limited-new-id")

      first =
        conn
        |> post(~p"/api/v1/auth/facebook", %{
          authentication_token: "limited-new",
          nonce: "limited-nonce"
        })
        |> json_response(200)
        |> Map.fetch!("data")

      second =
        build_conn()
        |> post(~p"/api/v1/auth/facebook", %{
          authentication_token: "limited-sign-in",
          nonce: "limited-nonce"
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert second["user"]["id"] == first["user"]["id"]

      identity = Repo.get_by!(UserIdentity, provider: :facebook, subject: "limited-new-id")
      assert identity.business_ids == []
    end

    test "Facebook Limited Login reaches the Classic email match", %{conn: conn} do
      expect_classic_not_found(:fbid, "limited-classic-id")
      expect_classic_lookup(:email, "classic@example.com", classic_profile(71_005, "Disa"))

      data =
        conn
        |> post(~p"/api/v1/auth/facebook", %{
          authentication_token: "limited-classic",
          nonce: "limited-nonce",
          install_id: "limited-install"
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["classic_found"]
      assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 71_005).matched_on == :email
    end

    test "Android Graph and iPhone Limited Login land in the same account", %{conn: conn} do
      expect_classic_not_found(:fbid, "facebook-new-id")
      expect_classic_not_found(:fbid, "facebook-new-old-id")
      expect_classic_not_found(:email, "facebook-new@example.com")

      android =
        conn
        |> post(~p"/api/v1/auth/facebook", %{access_token: "facebook-new"})
        |> json_response(200)
        |> get_in(["data", "user"])

      iphone =
        build_conn()
        |> post(~p"/api/v1/auth/facebook", %{
          authentication_token: "limited-same-account",
          nonce: "limited-nonce"
        })
        |> json_response(200)
        |> get_in(["data", "user"])

      assert iphone["id"] == android["id"]
    end

    test "Facebook rejects both credential shapes and neither" do
      for params <- [
            %{},
            %{
              access_token: "facebook-new",
              authentication_token: "limited-new",
              nonce: "limited-nonce"
            }
          ] do
        assert %{"errors" => [%{"code" => "INVALID_CREDENTIALS"}]} =
                 build_conn()
                 |> post(~p"/api/v1/auth/facebook", params)
                 |> json_response(401)
      end
    end

    test "classic_found says when the Classic account is already linked", %{conn: conn} do
      for {classic_id, fields, method} <- [
            {71_101, %{password_hash: "hash"}, "password"},
            {71_102, %{apple_sub: "owner-apple"}, "apple"},
            {71_103, %{facebook_id: "owner-facebook"}, "facebook"}
          ] do
        AccountsFixtures.user_fixture()
        |> User.classic_claim_changeset(
          Map.merge(
            %{classic_user_id: classic_id, classic_claimed_at: DateTime.utc_now()},
            fields
          )
        )
        |> Ecto.Changeset.change(password_hash: fields[:password_hash])
        |> Repo.update!()

        expect_classic_lookup(:email, "classic@example.com", classic_profile(classic_id, "Owned"))

        data =
          conn
          |> recycle()
          |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-classic", install_id: "i"})
          |> json_response(200)
          |> Map.fetch!("data")

        assert data["already_claimed"] == %{"sign_in_method" => method}

        expect_classic_not_found(:fbid, "facebook-current-id")
        expect_classic_lookup(:fbid, "facebook-classic-id", classic_profile(classic_id, "Owned"))

        data =
          conn
          |> recycle()
          |> post(~p"/api/v1/auth/facebook", %{access_token: "facebook-classic", install_id: "i"})
          |> json_response(200)
          |> Map.fetch!("data")

        assert data["already_claimed"] == %{"sign_in_method" => method}
      end
    end

    test "classic_found has no already_claimed for a free Classic account", %{conn: conn} do
      expect_classic_lookup(:email, "classic@example.com", classic_profile(71_104, "Free"))

      data =
        conn
        |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-classic", install_id: "i"})
        |> json_response(200)
        |> Map.fetch!("data")

      assert Map.fetch!(data, "already_claimed") == nil
    end

    test "Apple Classic match returns a redeemable install-bound ticket", %{conn: conn} do
      expect_classic_lookup(:email, "classic@example.com", classic_profile(71_001, "Bengt"))

      data =
        conn
        |> post(~p"/api/v1/auth/apple", %{
          identity_token: "apple-classic",
          install_id: "apple-install"
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{
               "classic_found" => true,
               "classic" => %{
                 "name" => "Bengt",
                 "new_account" => %{"username" => "Bengt", "email" => nil}
               },
               "ticket" => ticket,
               "expires_at" => expires_at
             } = data

      assert is_binary(expires_at)
      refute Repo.get_by(User, apple_sub: "apple-classic-sub")

      assert %{"user" => %{"id" => claimed_id}, "token" => claimed_token} =
               conn
               |> recycle()
               |> post(~p"/api/v1/classic/claim", %{
                 ticket: ticket,
                 install_id: "apple-install",
                 account: %{username: "bengt_returned"}
               })
               |> json_response(200)
               |> Map.fetch!("data")

      claimed = Repo.get_by!(User, apple_sub: "apple-classic-sub")
      assert claimed.id == claimed_id
      assert claimed.classic_user_id == 71_001
      assert claimed.username == "Bengt"
      assert claimed.classic_claim_method == :apple
      assert claimed.classic_matched_on == :email
      assert claimed.email == "classic@example.com"

      identity = Repo.get_by!(UserIdentity, provider: :apple, subject: "apple-classic-sub")
      assert identity.user_id == claimed.id
      assert identity.issuer_app == "com.oneapps.pidro"
      assert identity.email == "classic@example.com"
      assert identity.link_source == :claim
      assert is_binary(claimed_token)
      assert_token_user(conn, claimed_token, claimed_id)
    end

    test "Facebook checks business IDs and tickets the current app identity", %{conn: conn} do
      expect_classic_not_found(:fbid, "facebook-current-id")
      expect_classic_lookup(:fbid, "facebook-classic-id", classic_profile(71_002, "Birgit"))

      data =
        conn
        |> post(~p"/api/v1/auth/facebook", %{
          access_token: "facebook-classic",
          install_id: "facebook-install"
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{
               "classic_found" => true,
               "classic" => %{
                 "name" => "Birgit",
                 "new_account" => %{"username" => "Birgit", "email" => nil}
               },
               "ticket" => response_ticket
             } = data

      stored_ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 71_002)
      assert stored_ticket.provider_id == "facebook-current-id"
      assert stored_ticket.install_id == "facebook-install"

      assert %{"user" => %{"id" => claimed_id}, "token" => claimed_token} =
               conn
               |> recycle()
               |> post(~p"/api/v1/classic/claim", %{
                 ticket: response_ticket,
                 install_id: "facebook-install",
                 account: %{username: "birgit_returned"}
               })
               |> json_response(200)
               |> Map.fetch!("data")

      assert Repo.get!(User, claimed_id).username == "Birgit"
      assert_token_user(conn, claimed_token, claimed_id)
    end

    test "Apple creates a provider-linked account after a definitive Classic miss", %{conn: conn} do
      expect_classic_not_found(:email, "new@example.com")

      assert %{
               "user" => %{
                 "id" => user_id,
                 "username" => "Lucky Moose",
                 "display_name" => "Lucky Moose",
                 "guest" => false
               },
               "token" => token
             } =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-new"})
               |> json_response(200)
               |> Map.fetch!("data")

      user = Repo.get!(User, user_id)
      assert user.apple_sub == "apple-new-sub"
      assert user.facebook_id == nil
      assert user.email == "new@example.com"

      identity = Repo.get_by!(UserIdentity, provider: :apple, subject: "apple-new-sub")
      assert identity.user_id == user.id
      assert identity.issuer_app == "com.oneapps.pidro"
      assert identity.email == "new@example.com"
      assert identity.business_ids == []
      assert identity.link_source == :sign_up
      assert is_binary(token)
      assert_token_user(conn, token, user_id)
    end

    test "Apple creates from a valid subject when there is no verified email to match", %{
      conn: conn
    } do
      assert %{"user" => %{"id" => user_id}, "token" => token} =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-no-email"})
               |> json_response(200)
               |> Map.fetch!("data")

      user = Repo.get!(User, user_id)
      assert user.apple_sub == "apple-no-email-sub"
      assert user.display_name == "Lucky Moose"
      assert is_binary(token)
    end

    test "provider registration redraws a generated Classic-reserved name", %{conn: conn} do
      assert {:ok, _result} =
               ClassicNameReservations.import([%{id: 71_004, username: "Lucky Moose"}])

      Application.put_env(:pidro_server, :guest_names, RetryGuestNames)
      expect_classic_not_found(:email, "new@example.com")

      assert %{"user" => %{"username" => "Brave Badger", "display_name" => "Brave Badger"}} =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-new"})
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "Facebook creates a provider-linked account only after every Classic ID misses", %{
      conn: conn
    } do
      expect_classic_not_found(:fbid, "facebook-new-id")
      expect_classic_not_found(:fbid, "facebook-new-old-id")
      expect_classic_not_found(:email, "facebook-new@example.com")

      assert %{
               "user" => %{
                 "id" => user_id,
                 "username" => "Lucky Moose",
                 "display_name" => "Lucky Moose",
                 "guest" => false
               },
               "token" => token
             } =
               conn
               |> post(~p"/api/v1/auth/facebook", %{access_token: "facebook-new"})
               |> json_response(200)
               |> Map.fetch!("data")

      user = Repo.get!(User, user_id)
      assert user.facebook_id == "facebook-new-id"
      assert user.apple_sub == nil
      assert user.email == "facebook-new@example.com"

      identity =
        Repo.get_by!(UserIdentity, provider: :facebook, subject: "facebook-new-id")

      assert identity.user_id == user.id
      assert identity.issuer_app == "facebook-app"
      assert identity.email == "facebook-new@example.com"
      assert identity.business_ids == ["facebook-new-old-id"]
      assert identity.link_source == :sign_up
      assert is_binary(token)
      assert_token_user(conn, token, user_id)
    end

    test "a Classic match without install_id returns the binding error and creates nothing", %{
      conn: conn
    } do
      expect_classic_lookup(:email, "classic@example.com", classic_profile(71_003, "Carin"))

      assert %{"errors" => [%{"code" => "CLAIM_BINDING_REQUIRED"}]} =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-classic"})
               |> json_response(422)

      refute Repo.get_by(User, apple_sub: "apple-classic-sub")
      refute Repo.get_by(ClassicClaimTicket, classic_user_id: 71_003)
    end

    test "Apple returns 503 and creates nothing when Classic is unavailable", %{conn: conn} do
      expect_classic_unavailable(:email, "down@example.com")

      assert %{"errors" => [%{"code" => "PROVIDER_UNAVAILABLE"}]} =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-down"})
               |> json_response(503)

      refute Repo.get_by(User, apple_sub: "apple-down-sub")
    end

    test "Facebook returns 503 after an earlier Classic miss and creates nothing", %{conn: conn} do
      expect_classic_not_found(:fbid, "facebook-down-id")
      expect_classic_unavailable(:fbid, "facebook-old-id")

      assert %{"errors" => [%{"code" => "PROVIDER_UNAVAILABLE"}]} =
               conn
               |> post(~p"/api/v1/auth/facebook", %{access_token: "facebook-down"})
               |> json_response(503)

      refute Repo.get_by(User, facebook_id: "facebook-down-id")
    end

    test "invalid provider proof remains unauthorized", %{conn: conn} do
      assert %{"errors" => [%{"code" => "INVALID_CREDENTIALS"}]} =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "wrong"})
               |> json_response(401)
    end
  end

  describe "me" do
    test "includes a nil display_name for existing users", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> get(~p"/api/v1/auth/me")

      assert %{
               "user" => %{
                 "id" => id,
                 "display_name" => nil,
                 "age_band" => "unknown",
                 "terms_version" => nil,
                 "share_slug" => share_slug
               }
             } = json_response(conn, 200)["data"]

      assert id == user.id
      assert share_slug == user.share_slug
      assert share_slug =~ ~r/\A[a-z0-9-]{3,30}\z/
    end
  end

  describe "age" do
    test "stores the declaration once and returns the me shape", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/auth/age", %{age_band: "18_plus", terms_version: "1"})
        |> json_response(200)

      assert response["data"]["user"]["id"] == user.id
      assert response["data"]["user"]["age_band"] == "18_plus"
      assert response["data"]["user"]["terms_version"] == "1"
      assert_age_terms(Repo.get!(User, user.id), "18_plus", "1")
    end

    test "returns 409 after the age band is set", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      token = Token.generate(user)

      assert conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> post(~p"/api/v1/auth/age", %{age_band: "13_17"})
             |> json_response(200)

      assert %{"errors" => [%{"code" => "AGE_ALREADY_SET"}]} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{token}")
               |> post(~p"/api/v1/auth/age", %{age_band: "18_plus"})
               |> json_response(409)

      assert Repo.get!(User, user.id).age_band == "13_17"
    end

    test "returns 403 without changing the row for under-13", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      assert %{"errors" => [%{"code" => "AGE_NOT_ELIGIBLE"}]} =
               conn
               |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
               |> post(~p"/api/v1/auth/age", %{age_band: "under_13", terms_version: "1"})
               |> json_response(403)

      assert Repo.get!(User, user.id).age_band == "unknown"
      assert Repo.get!(User, user.id).terms_version == nil
    end

    test "returns 422 for missing and invalid fields" do
      user = AccountsFixtures.user_fixture()
      token = Token.generate(user)

      for body <- [%{}, %{age_band: "adult"}, %{age_band: "18_plus", terms_version: ""}] do
        assert %{"errors" => [_ | _]} =
                 build_conn()
                 |> put_req_header("authorization", "Bearer #{token}")
                 |> post(~p"/api/v1/auth/age", body)
                 |> json_response(422)
      end

      assert Repo.get!(User, user.id).age_band == "unknown"
    end

    test "requires authentication", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/v1/auth/age", %{age_band: "18_plus"}), 401)
    end
  end

  defp provider_user!(field, value) do
    provider = if field == :apple_sub, do: :apple, else: :facebook

    user =
      AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(%{field => value})
      |> Repo.update!()

    {:ok, user} =
      UserIdentities.link(
        user,
        %{
          provider: provider,
          subject: value,
          issuer_app: nil,
          email: nil,
          email_is_relay: false,
          business_ids: nil
        },
        :backfill,
        user.inserted_at
      )

    user
  end

  defp expect_classic_lookup(field, value, profile) do
    Req.Test.expect(PidroServer.Accounts.ClassicClient, fn conn ->
      assert conn.request_path == "/internal/claims/lookup"
      assert Plug.Conn.fetch_query_params(conn).query_params[Atom.to_string(field)] == value
      Req.Test.json(conn, %{"classic" => profile})
    end)
  end

  defp expect_classic_not_found(field, value) do
    Req.Test.expect(PidroServer.Accounts.ClassicClient, fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params[Atom.to_string(field)] == value
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})
    end)
  end

  defp expect_classic_unavailable(field, value) do
    Req.Test.stub(PidroServer.Accounts.ClassicClient, fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params[Atom.to_string(field)] == value
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
    end)
  end

  defp classic_profile(id, username) do
    %{
      "id" => id,
      "username" => username,
      "member_since" => "2011-01-02T00:00:00Z",
      "level" => 42,
      "games" => %{"legacy_played_games" => 700, "total_game" => 0}
    }
  end

  describe "token revocation" do
    test "a bumped version yields 401 for the old token and 200 for a fresh one", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      old_token = Token.generate(user)

      assert json_response(me(conn, old_token), 200)

      {:ok, bumped} = Auth.bump_token_version(user)

      assert %{"errors" => %{"detail" => "Unauthorized"}} =
               json_response(me(build_conn(), old_token), 401)

      assert %{"user" => %{"id" => id}} =
               json_response(me(build_conn(), Token.generate(bumped)), 200)["data"]

      assert id == user.id
    end

    test "a completed password reset revokes the old token and the returned token works", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture(%{username: "reset_revokes"})
      old_token = Token.generate(user)
      assert json_response(me(conn, old_token), 200)

      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      conn =
        post(build_conn(), ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "new password!"
        })

      assert %{"token" => new_token, "user" => %{"username" => "reset_revokes"}} =
               json_response(conn, 200)["data"]

      assert json_response(me(build_conn(), old_token), 401)

      assert %{"user" => %{"id" => id}} =
               json_response(me(build_conn(), new_token), 200)["data"]

      assert id == user.id
      assert {:ok, %{v: 1}} = Token.verify(new_token)
    end
  end

  defp me(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(~p"/api/v1/auth/me")
  end

  defp assert_token_user(conn, token, user_id) do
    assert %{"user" => %{"id" => ^user_id}} =
             conn
             |> recycle()
             |> me(token)
             |> json_response(200)
             |> Map.fetch!("data")
  end

  defp data(conn, status), do: json_response(conn, status)["data"]

  defp await_background_mail do
    for pid <- Task.Supervisor.children(PidroServer.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  describe "password reset" do
    test "request returns a generic response and debug reset url for existing users", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture(%{username: "mfahle", email: "mfahle@example.com"})

      conn =
        post(conn, ~p"/api/v1/auth/password-reset", %{
          "identifier" => user.username
        })

      assert %{
               "message" =>
                 "If an account exists for that username or email, a reset link has been sent.",
               "reset_token" => token,
               "reset_url" => reset_url
             } = json_response(conn, 200)["data"]

      assert is_binary(token)
      assert reset_url =~ "/reset-password?token="

      assert_receive {:email, %{to: [{"mfahle", "mfahle@example.com"}]} = email}
      assert email.text_body =~ reset_url
      assert email.html_body =~ "Pidro, the card game from Ostrobothnia"
      assert email.html_body =~ "Choose a new password"
      assert email.text_body =~ "Hi mfahle, someone asked to reset"
    end

    test "a blank username gets a natural greeting", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{email: "blank-name@example.com"})
      from(u in User, where: u.id == ^user.id) |> Repo.update_all(set: [username: "   "])

      assert post(conn, ~p"/api/v1/auth/password-reset", %{identifier: user.email})
             |> json_response(200)

      assert_receive {:email, email}
      assert email.html_body =~ "Hi there, someone asked to reset"
      assert email.text_body =~ "Hi there, someone asked to reset"
    end

    test "request answers before the mail is delivered, and the mail follows", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "mfahle", email: "mfahle@example.com"})
      mailer_env = Application.fetch_env!(:pidro_server, PidroServer.Mailer)
      Application.put_env(:pidro_server, PidroServer.Mailer, adapter: BlockingMailer)
      on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Mailer, mailer_env) end)

      conn = post(conn, ~p"/api/v1/auth/password-reset", %{"identifier" => user.username})

      assert %{"reset_token" => token} = json_response(conn, 200)["data"]
      assert_receive {:mail_waiting, sender}
      refute_received {:email, _email}

      send(sender, :deliver)

      assert_receive {:email, email}
      assert email.text_body =~ URI.encode_www_form(token)
    end

    test "a blocked template read cannot delay the reset response", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{email: "template-wait@example.com"})
      handler = "reset-template-wait-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:pidro_server, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata[:source] == "email_templates" do
            send(test_pid, {:template_waiting, self()})

            receive do
              :continue_template -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      request =
        Task.async(fn ->
          post(conn, ~p"/api/v1/auth/password-reset", %{"identifier" => user.username})
        end)

      assert_receive {:template_waiting, sender}, 1_000

      try do
        assert {:ok, response} = Task.yield(request, 500)
        assert json_response(response, 200)["data"]["message"] =~ "If an account exists"
        refute_received {:email, _}
      after
        send(sender, :continue_template)
      end

      assert_receive {:email, email}, 1_000
      assert email.html_body =~ "Choose a new password"
    end

    test "request does not reveal missing users", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/password-reset", %{
          "identifier" => "missing"
        })

      assert %{
               "message" =>
                 "If an account exists for that username or email, a reset link has been sent."
             } = json_response(conn, 200)["data"]

      refute Map.has_key?(json_response(conn, 200)["data"], "reset_token")
    end

    for {failure, mailer} <- [
          {"returns an error", ErrorMailer},
          {"raises", RaiseMailer},
          {"exits", ExitMailer}
        ] do
      test "a mailer that #{failure} answers a known address like an unknown one", %{conn: conn} do
        user = AccountsFixtures.user_fixture(%{username: "mfahle", email: "mfahle@example.com"})

        mailer_env = Application.fetch_env!(:pidro_server, PidroServer.Mailer)
        reset_env = Application.fetch_env!(:pidro_server, :password_reset)

        Application.put_env(:pidro_server, PidroServer.Mailer, adapter: unquote(mailer))
        Application.put_env(:pidro_server, :password_reset, debug_tokens: false)

        on_exit(fn ->
          Application.put_env(:pidro_server, PidroServer.Mailer, mailer_env)
          Application.put_env(:pidro_server, :password_reset, reset_env)
        end)

        log =
          capture_log(fn ->
            known = post(conn, ~p"/api/v1/auth/password-reset", %{"identifier" => user.username})
            send(self(), {:known, json_response(known, 200)})
            await_background_mail()
          end)

        unknown = post(conn, ~p"/api/v1/auth/password-reset", %{"identifier" => "missing"})

        assert_received {:known, known_body}
        assert known_body == json_response(unknown, 200)
        assert log =~ "Password reset email delivery failed"
        refute log =~ "reset-password?token="
      end
    end

    test "confirm resets password and signs user in", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "mfahle"})
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      conn =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "new password!"
        })

      assert %{"token" => auth_token, "user" => %{"username" => "mfahle"}} =
               json_response(conn, 200)["data"]

      assert is_binary(auth_token)
      assert {:ok, _user} = Auth.authenticate_user("mfahle", "new password!")
      assert {:error, :invalid_credentials} = Auth.authenticate_user("mfahle", "hello world!")
    end

    test "confirm rejects reused tokens", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      conn =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "new password!"
        })

      assert json_response(conn, 200)

      conn =
        post(build_conn(), ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "another password!"
        })

      assert %{"errors" => [%{"code" => "INVALID_OR_EXPIRED_PASSWORD_RESET_TOKEN"}]} =
               json_response(conn, 422)

      assert json_response(conn, 422)["error_code"] == "invalid_or_expired_password_reset_token"
      assert json_response(conn, 422)["error_params"] == %{}
    end
  end

  describe "login with email" do
    test "R14: the username field accepts the account's email address", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{email: "marcel@example.com"})

      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "username" => "Marcel@example.com",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"user" => %{"id" => id}, "token" => token} = json_response(conn, 200)["data"]
      assert id == user.id
      assert json_response(me(build_conn(), token), 200)
      assert %DateTime{} = Repo.get!(User, user.id).last_seen_at
    end
  end

  describe "guest" do
    setup :start_room_manager

    test "201 creates a direct guest without an invitation", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/v1/auth/guest", %{
          "display_name" => "Anna",
          "creation_token" => Ecto.UUID.generate(),
          "install_id" => "device-direct",
          "platform" => "android"
        })
        |> json_response(201)

      assert %{"user" => user, "token" => token} = response["data"]
      refute Map.has_key?(response["data"], "state")
      assert user["guest"]
      assert user["display_name"] == "Anna"
      assert %{"user" => %{"id" => id}} = json_response(me(build_conn(), token), 200)["data"]
      assert id == user["id"]
    end

    test "201 generates a public name when direct creation omits it", %{conn: conn} do
      creation_token = Ecto.UUID.generate()
      params = %{"creation_token" => creation_token, "install_id" => "device-generated"}

      first = conn |> post(~p"/api/v1/auth/guest", params) |> data(201)
      second = build_conn() |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert first["user"]["display_name"] =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
      assert second["user"]["id"] == first["user"]["id"]
      assert second["user"]["display_name"] == first["user"]["display_name"]
    end

    test "201 generates a public name when direct creation supplies null", %{conn: conn} do
      assert %{"user" => %{"display_name" => display_name}} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => nil,
                 "creation_token" => Ecto.UUID.generate()
               })
               |> data(201)

      assert display_name =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
    end

    test "a direct retry returns the same guest instead of creating another", %{conn: conn} do
      creation_token = Ecto.UUID.generate()

      params = %{
        "display_name" => "Anna",
        "creation_token" => creation_token,
        "install_id" => "device-retry"
      }

      first = conn |> post(~p"/api/v1/auth/guest", params) |> data(201)
      second = build_conn() |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert second["user"]["id"] == first["user"]["id"]
      assert json_response(me(build_conn(), second["token"]), 200)
      assert Repo.aggregate(from(u in User, where: u.install_id == "device-retry"), :count) == 1
    end

    test "stores a declaration and an idempotent retry cannot overwrite it", %{conn: conn} do
      creation_token = Ecto.UUID.generate()

      first =
        conn
        |> post(~p"/api/v1/auth/guest", %{
          "display_name" => "Anna",
          "creation_token" => creation_token,
          "age_band" => "13_17",
          "terms_version" => "1"
        })
        |> data(201)

      second =
        build_conn()
        |> post(~p"/api/v1/auth/guest", %{
          "display_name" => "Anna",
          "creation_token" => creation_token,
          "age_band" => "18_plus",
          "terms_version" => "2"
        })
        |> data(201)

      assert second["user"]["id"] == first["user"]["id"]
      assert second["user"]["age_band"] == "13_17"
      assert_age_terms(Repo.get!(User, first["user"]["id"]), "13_17", "1")
    end

    test "refuses or validates declarations before creating a guest", %{conn: conn} do
      count = Repo.aggregate(User, :count)

      assert %{
               "errors" => [%{"code" => "AGE_NOT_ELIGIBLE"}],
               "error_code" => "age_not_eligible",
               "error_params" => %{}
             } =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "creation_token" => Ecto.UUID.generate(),
                 "age_band" => "under_13"
               })
               |> json_response(403)

      assert %{"errors" => [%{"code" => "age_band"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "creation_token" => Ecto.UUID.generate(),
                 "age_band" => "adult"
               })
               |> json_response(422)

      assert Repo.aggregate(User, :count) == count
    end

    test "a creation token cannot recover an account after it is upgraded", %{conn: conn} do
      creation_token = Ecto.UUID.generate()
      params = %{"display_name" => "Anna", "creation_token" => creation_token}

      %{"user" => %{"id" => id}, "token" => token} =
        conn |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert build_conn()
             |> put_req_header("authorization", "Bearer #{token}")
             |> post(~p"/api/v1/auth/upgrade", %{
               "email" => "anna@example.com",
               "password" => "password123"
             })
             |> json_response(200)

      assert %{"errors" => [%{"code" => "CREATION_CONFLICT"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", params)
               |> json_response(409)

      refute Repo.get!(User, id).guest
      assert Repo.aggregate(User, :count) == 1
    end

    test "direct entry requires a valid creation token", %{conn: conn} do
      assert %{"errors" => [%{"code" => "creation_token"}]} =
               conn
               |> post(~p"/api/v1/auth/guest", %{"display_name" => "Anna"})
               |> json_response(422)

      assert %{"errors" => [%{"code" => "creation_token"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "creation_token" => "not-a-uuid"
               })
               |> json_response(422)

      assert %{"errors" => [%{"code" => "creation_token"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "creation_token" => "sixteen-byte-key"
               })
               |> json_response(422)

      refute Repo.exists?(from(u in User, where: u.display_name == "Anna"))
    end

    test "a supplied invalid invite never falls back to direct entry", %{conn: conn} do
      assert conn
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Anna",
               "creation_token" => Ecto.UUID.generate(),
               "invite_code" => "ZZZZZZZZ"
             })
             |> json_response(404)

      refute Repo.exists?(from(u in User, where: u.display_name == "Anna"))
    end

    test "201 with a guest user, a working token and the invite state", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      response =
        conn
        |> post(~p"/api/v1/auth/guest", %{
          "display_name" => "Anna",
          "invite_code" => invite.code,
          "install_id" => "device-1",
          "platform" => "ios"
        })
        |> json_response(201)

      assert %{"user" => user, "token" => token, "state" => "open"} = response["data"]
      assert user["guest"] == true
      assert user["display_name"] == "Anna"
      assert user["username"] =~ ~r/\Aguest_/
      refute Map.has_key?(user, "install_id")

      assert %{"user" => %{"id" => id}} = json_response(me(build_conn(), token), 200)["data"]
      assert id == user["id"]
      assert %DateTime{} = Repo.get!(User, id).last_seen_at

      assert [%Event{kind: "guest_created", platform: "ios", user_id: ^id}] =
               invite_events(invite, "guest_created")
    end

    test "an invited retry returns one guest and records one creation event", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      params = %{
        "display_name" => "Anna",
        "invite_code" => invite.code,
        "creation_token" => Ecto.UUID.generate(),
        "platform" => "ios"
      }

      first = conn |> post(~p"/api/v1/auth/guest", params) |> data(201)
      second = build_conn() |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert second["user"]["id"] == first["user"]["id"]
      assert second["state"] == "open"
      assert [%Event{kind: "guest_created"}] = invite_events(invite, "guest_created")
    end

    test "a full table still creates the guest and answers state full", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      fill_with_held_seat!(room)

      assert %{"user" => %{"guest" => true}, "state" => "full"} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Late",
                 "invite_code" => invite.code
               })
               |> data(201)
    end

    test "a revoked invite is 410 INVITE_REVOKED and an expired one 410 INVITE_EXPIRED", %{
      conn: conn
    } do
      {host, room} = host_and_room()
      {:ok, revoked} = room |> mint!(host) |> Invites.revoke()

      assert %{"errors" => [%{"code" => "INVITE_REVOKED"}]} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => revoked.code
               })
               |> json_response(410)

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      expired = room |> mint!(host) |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert %{"errors" => [%{"code" => "INVITE_EXPIRED"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => expired.code
               })
               |> json_response(410)

      refute Repo.exists?(from(u in User, where: u.display_name == "Anna"))
    end

    test "an unknown invite code is 404 and a bad platform is 422 on platform", %{conn: conn} do
      assert conn
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Anna",
               "invite_code" => "ZZZZZZZZ"
             })
             |> json_response(404)

      {host, room} = host_and_room()
      invite = mint!(room, host)

      assert %{"errors" => [%{"code" => "platform"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => invite.code,
                 "platform" => "windows"
               })
               |> json_response(422)
    end

    test "AE13: a look-alike of a connected player's name is 422 on display_name", %{conn: conn} do
      {host, room} = host_and_room(%{display_name: "Marcel"})
      invite = mint!(room, host)

      assert %{"errors" => [%{"code" => "display_name"}]} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "marcél",
                 "invite_code" => invite.code
               })
               |> json_response(422)
    end

    test "AE15: a name held by a reconnecting seat is accepted", %{conn: conn} do
      {host, room} = host_and_room(%{display_name: "Marcel"})
      invite = mint!(room, host)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, anna.id)
      :ok = RoomManager.handle_player_disconnect(room.code, anna.id)

      assert %{"user" => %{"display_name" => "Anna"}} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => invite.code
               })
               |> data(201)
    end

    test "an invited guest gets a generated display_name when it is missing", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      assert %{"user" => %{"display_name" => display_name}} =
               conn |> post(~p"/api/v1/auth/guest", %{"invite_code" => invite.code}) |> data(201)

      assert display_name =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
    end

    test "guest_create at limit 1: the second creation from one address is 429", %{conn: conn} do
      with_limit(:guest_create, 1, 3_600_000)
      {host, room} = host_and_room()
      invite = mint!(room, host)
      params = %{"display_name" => "Anna", "invite_code" => invite.code}

      assert conn
             |> from_ip({10, 3, 0, 1})
             |> post(~p"/api/v1/auth/guest", params)
             |> json_response(201)

      assert build_conn()
             |> from_ip({10, 3, 0, 1})
             |> post(~p"/api/v1/auth/guest", Map.put(params, "display_name", "Ben"))
             |> json_response(429)
    end

    test "guest_create_install at limit 1: the second creation with one install_id is 429 across addresses",
         %{conn: conn} do
      with_limit(:guest_create_install, 1, 3_600_000)
      {host, room} = host_and_room()
      invite = mint!(room, host)

      params = %{
        "display_name" => "Anna",
        "invite_code" => invite.code,
        "install_id" => "device-shared"
      }

      assert conn
             |> from_ip({10, 3, 0, 2})
             |> post(~p"/api/v1/auth/guest", params)
             |> json_response(201)

      assert build_conn()
             |> from_ip({10, 3, 0, 3})
             |> post(~p"/api/v1/auth/guest", Map.put(params, "display_name", "Ben"))
             |> json_response(429)

      # Without an install id the install bucket is skipped.
      assert build_conn()
             |> from_ip({10, 3, 0, 4})
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Chris",
               "invite_code" => invite.code
             })
             |> json_response(201)
    end

    test "direct creation keeps the install abuse limit", %{conn: conn} do
      with_limit(:guest_create_install, 1, 3_600_000)

      assert conn
             |> from_ip({10, 3, 1, 1})
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Anna",
               "creation_token" => Ecto.UUID.generate(),
               "install_id" => "direct-shared"
             })
             |> json_response(201)

      assert build_conn()
             |> from_ip({10, 3, 1, 2})
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Ben",
               "creation_token" => Ecto.UUID.generate(),
               "install_id" => "direct-shared"
             })
             |> json_response(429)
    end
  end

  describe "upgrade" do
    setup :start_room_manager

    test "AE9: 200 with a new token, the old token 401, guest false and a guest_upgraded event",
         %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      {:ok, _room, _position, _honored} = RoomManager.claim_seat(room.code, room.id, anna.id)

      {:ok, _redemption} =
        Invites.record_redemption(invite, %{user_id: anna.id, position: :south})

      old_token = Token.generate(anna)
      assert json_response(me(conn, old_token), 200)

      response =
        build_conn()
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post(~p"/api/v1/auth/upgrade", %{
          "email" => "Anna@example.com",
          "password" => "anna-secret-1"
        })
        |> json_response(200)

      assert %{
               "user" => %{
                 "id" => id,
                 "guest" => false,
                 "display_name" => "Anna",
                 "share_slug" => share_slug
               },
               "token" => token
             } =
               response["data"]

      assert id == anna.id
      assert anna.share_slug == nil
      assert share_slug == User.share_slug(anna.username, fn _ -> false end)
      assert json_response(me(build_conn(), old_token), 401)
      assert json_response(me(build_conn(), token), 200)

      assert [%Event{kind: "guest_upgraded", user_id: ^id}] =
               invite_events(invite, "guest_upgraded")

      assert %{"user" => %{"id" => ^id}} =
               build_conn()
               |> post(~p"/api/v1/auth/login", %{
                 "username" => "anna@example.com",
                 "password" => "anna-secret-1"
               })
               |> data(200)
    end

    test "a registered caller is 409 NOT_A_GUEST", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      assert %{"errors" => [%{"code" => "NOT_A_GUEST"}]} =
               conn
               |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
               |> post(~p"/api/v1/auth/upgrade", %{
                 "email" => "new@example.com",
                 "password" => "long-enough"
               })
               |> json_response(409)
    end

    test "stores a valid declaration during upgrade", %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()

      response =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
        |> post(~p"/api/v1/auth/upgrade", %{
          "email" => "declared-upgrade@example.com",
          "password" => "long-enough",
          "age_band" => "18_plus",
          "terms_version" => "1"
        })
        |> json_response(200)

      assert get_in(response, ["data", "user", "age_band"]) == "18_plus"
      refute Repo.get!(User, guest.id).guest
      assert_age_terms(Repo.get!(User, guest.id), "18_plus", "1")
    end

    test "refuses or validates declarations before changing a guest" do
      for {declaration, status} <- [
            {%{"age_band" => "under_13"}, 403},
            {%{"terms_version" => ""}, 422}
          ] do
        guest = AccountsFixtures.guest_fixture()

        body =
          Map.merge(
            %{"email" => "#{guest.id}@example.com", "password" => "long-enough"},
            declaration
          )

        build_conn()
        |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
        |> post(~p"/api/v1/auth/upgrade", body)
        |> json_response(status)

        persisted = Repo.get!(User, guest.id)
        assert persisted.guest
        assert persisted.age_band == "unknown"
      end
    end

    test "a taken email is 409 EMAIL_TAKEN and a taken username 409 USERNAME_TAKEN", %{
      conn: conn
    } do
      AccountsFixtures.user_fixture(%{email: "taken@example.com", username: "taken_name"})
      guest = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "EMAIL_TAKEN"}]} =
               conn
               |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
               |> post(~p"/api/v1/auth/upgrade", %{
                 "email" => "TAKEN@example.com",
                 "password" => "long-enough"
               })
               |> json_response(409)

      assert %{"errors" => [%{"code" => "USERNAME_TAKEN"}]} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
               |> post(~p"/api/v1/auth/upgrade", %{
                 "email" => "free@example.com",
                 "password" => "long-enough",
                 "username" => "taken_name"
               })
               |> json_response(409)

      assert Repo.get!(User, guest.id).guest
    end

    test "a missing password, a short password and a malformed email are 422", %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()

      for body <- [
            %{"email" => "ok@example.com"},
            %{"email" => "ok@example.com", "password" => "1234567"},
            %{"email" => "not-an-email", "password" => "long-enough"}
          ] do
        assert %{"errors" => [_ | _]} =
                 build_conn()
                 |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
                 |> post(~p"/api/v1/auth/upgrade", body)
                 |> json_response(422)
      end

      assert json_response(me(conn, Token.generate(guest)), 200)
    end

    test "auth_upgrade at limit 1: the second attempt from one address is 429", %{conn: conn} do
      with_limit(:auth_upgrade, 1, 600_000)
      guest = AccountsFixtures.guest_fixture()
      body = %{"email" => "bad", "password" => "x"}

      assert conn
             |> from_ip({10, 3, 0, 5})
             |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
             |> post(~p"/api/v1/auth/upgrade", body)
             |> json_response(422)

      assert build_conn()
             |> from_ip({10, 3, 0, 5})
             |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
             |> post(~p"/api/v1/auth/upgrade", body)
             |> json_response(429)
    end
  end

  describe "delete_me" do
    setup :start_room_manager

    test "deleting an account during play leaves a permanent bot", %{conn: conn} do
      {_host, room} = host_and_room()
      leaver = AccountsFixtures.guest_fixture()
      others = Enum.map(1..2, fn _ -> AccountsFixtures.guest_fixture() end)
      assert {:ok, _, position} = RoomManager.join_room(room.code, leaver.id)
      for user <- others, do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))
      PidroServer.RoomFixtures.ready_room(room.code)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(leaver)}")
        |> delete(~p"/api/v1/auth/me")

      assert response(conn, 204)
      assert Repo.get(User, leaver.id) == nil
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing
      assert updated.seats[position].occupant_type == :bot
      assert Process.alive?(updated.seats[position].bot_pid)
      assert updated.seats[position].reserved_for == nil
    end

    test "a Classic account can be claimed again by a new account after deletion", %{conn: conn} do
      {:ok, _} = ClassicNameReservations.import([%{id: 71_000, username: "Veteran"}])
      old = AccountsFixtures.user_fixture()

      {:ok, %{ticket: ticket}} =
        ClassicClaims.issue_ticket(%{
          classic_user_id: 71_000,
          method: :password,
          user_id: old.id,
          legacy_data: %{classic_user_id: 71_000, xp: 300}
        })

      {:ok, claimed} = ClassicClaims.redeem(ticket, old, %{})
      assert claimed.classic_user_id == 71_000

      assert conn
             |> put_req_header("authorization", "Bearer #{Token.generate(claimed)}")
             |> delete(~p"/api/v1/auth/me")
             |> response(204)

      Req.Test.expect(PidroServer.Accounts.ClassicClient, fn classic_conn ->
        Req.Test.json(classic_conn, %{
          "classic" => %{
            "id" => 71_000,
            "username" => "Veteran",
            "member_since" => "2011-01-02T00:00:00Z",
            "xp" => 300,
            "level" => 5,
            "games" => %{"legacy_played_games" => 0, "total_game" => 10}
          }
        })
      end)

      fresh = AccountsFixtures.user_fixture()
      auth = "Bearer #{Token.generate(fresh)}"

      data =
        build_conn()
        |> put_req_header("authorization", auth)
        |> post(~p"/api/v1/classic/verify", %{method: "password", login: "a", password: "b"})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["already_claimed"] == nil
      assert data["classic"]["name"] == "Veteran"

      assert %{"user" => %{"id" => id}} =
               build_conn()
               |> put_req_header("authorization", auth)
               |> post(~p"/api/v1/classic/claim", %{ticket: data["ticket"]})
               |> json_response(200)
               |> Map.fetch!("data")

      assert id == fresh.id
      assert Repo.get!(User, fresh.id).classic_user_id == 71_000
      assert Repo.get_by!(PlayerProfile, user_id: fresh.id).veteran_xp == 300
      assert ClassicNameReservations.reserved?("Veteran")

      assert %{classic_user_id: 71_000, username: "Veteran"} =
               Repo.get!(ClassicNameReservation, 71_000)
    end

    test "AE10: 204, the token is dead afterwards and the seat is vacant", %{conn: conn} do
      {_host, room} = host_and_room()
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, ben.id)
      token = Token.generate(ben)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete(~p"/api/v1/auth/me")

      assert response(conn, 204)
      assert json_response(me(build_conn(), token), 401)
      assert is_nil(Repo.get(User, ben.id))

      {:ok, vacated} = RoomManager.get_room(room.code)
      assert vacated.positions.east == nil
    end
  end

  defp start_room_manager(_context) do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  defp host_and_room(host_attrs \\ %{}) do
    host = AccountsFixtures.user_fixture(host_attrs)
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Invited"})
    {host, room}
  end

  defp mint!(room, host) do
    {:ok, invite} =
      Invites.create_invite(%{room_id: room.id, room_code: room.code, host_user_id: host.id})

    invite
  end

  # Four positions taken while one seat is held keeps the room `:waiting`.
  defp fill_with_held_seat!(room) do
    [a, b, c] = for _ <- 1..3, do: AccountsFixtures.user_fixture()
    {:ok, _room, _pos} = RoomManager.join_room(room.code, a.id)
    {:ok, _room, _pos} = RoomManager.join_room(room.code, b.id)
    :ok = RoomManager.handle_player_disconnect(room.code, a.id)
    {:ok, full, _pos} = RoomManager.join_room(room.code, c.id)
    assert full.status == :waiting
    full
  end

  defp invite_events(invite, kind) do
    Repo.all(from(e in Event, where: e.invite_id == ^invite.id and e.kind == ^kind))
  end

  describe "rate limiting" do
    # Shares the node-wide Hammer ETS table (reset by RateLimitCase before each
    # test); the module is already async: false.
    test "AE1: the second login from one IP inside the window is 429 with Retry-After", %{
      conn: conn
    } do
      with_limit(:login, 1, 60_000)
      user = AccountsFixtures.user_fixture()
      params = %{"username" => user.username, "password" => "hello world!"}

      assert conn
             |> from_ip({10, 1, 0, 1})
             |> post(~p"/api/v1/auth/login", params)
             |> json_response(200)

      denied = build_conn() |> from_ip({10, 1, 0, 1}) |> post(~p"/api/v1/auth/login", params)

      assert %{"errors" => [%{"code" => "RATE_LIMITED", "title" => "Too Many Requests"}]} =
               json_response(denied, 429)

      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert String.to_integer(retry_after) in 1..60
    end

    test "AE12: the identifier bucket is shared across case, whitespace and IPs for an unknown account",
         %{conn: conn} do
      with_limit(:password_reset_identifier, 1, 3_600_000)

      assert conn
             |> from_ip({10, 1, 0, 2})
             |> post(~p"/api/v1/auth/password-reset", %{"identifier" => "Anna@x.test"})
             |> json_response(200)

      denied =
        build_conn()
        |> from_ip({10, 1, 0, 3})
        |> post(~p"/api/v1/auth/password-reset", %{"identifier" => " anna@x.test "})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
    end

    test "AE12: the identifier bucket is shared the same way for an existing account", %{
      conn: conn
    } do
      with_limit(:password_reset_identifier, 1, 3_600_000)
      AccountsFixtures.user_fixture(%{username: "anna", email: "anna@x.test"})

      assert conn
             |> from_ip({10, 1, 0, 4})
             |> post(~p"/api/v1/auth/password-reset", %{"identifier" => "Anna@x.test"})
             |> json_response(200)

      denied =
        build_conn()
        |> from_ip({10, 1, 0, 5})
        |> post(~p"/api/v1/auth/password-reset", %{"identifier" => " anna@x.test "})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
      await_background_mail()
    end

    test "a missing or non-binary identifier skips the identifier bucket, never 500s and still counts against the IP bucket",
         %{conn: conn} do
      with_limit(:password_reset, 1, 900_000)
      with_limit(:password_reset_identifier, 1, 3_600_000)

      log =
        capture_log(fn ->
          missing = conn |> from_ip({10, 1, 0, 6}) |> post(~p"/api/v1/auth/password-reset", %{})
          assert missing.status in [200, 422]

          listy =
            build_conn()
            |> from_ip({10, 1, 0, 7})
            |> post(~p"/api/v1/auth/password-reset", %{"identifier" => ["a"]})

          assert listy.status in [200, 422]
        end)

      refute log =~ "[error]"

      # The IP bucket counted the first request although the identifier bucket was skipped.
      denied =
        build_conn() |> from_ip({10, 1, 0, 6}) |> post(~p"/api/v1/auth/password-reset", %{})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
    end

    test "password-reset/confirm is limited per IP", %{conn: conn} do
      with_limit(:password_reset_confirm, 1, 900_000)
      params = %{"token" => "not-a-real-token", "password" => "new password!"}

      assert conn
             |> from_ip({10, 1, 0, 8})
             |> post(~p"/api/v1/auth/password-reset/confirm", params)
             |> json_response(422)

      assert build_conn()
             |> from_ip({10, 1, 0, 8})
             |> post(~p"/api/v1/auth/password-reset/confirm", params)
             |> json_response(429)
    end

    test "register is limited per IP", %{conn: conn} do
      with_limit(:register, 1, 600_000)
      params = %{"user" => %{"username" => "rl", "email" => "bad", "password" => "x"}}

      assert conn
             |> from_ip({10, 1, 0, 9})
             |> post(~p"/api/v1/auth/register", params)
             |> json_response(422)

      assert build_conn()
             |> from_ip({10, 1, 0, 9})
             |> post(~p"/api/v1/auth/register", params)
             |> json_response(429)
    end
  end

  defp assert_age_terms(user, age_band, terms_version) do
    assert user.age_band == age_band
    assert user.terms_version == terms_version
    assert %DateTime{} = user.age_declared_at
    assert %DateTime{} = user.terms_accepted_at
    user
  end
end
