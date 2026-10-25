defmodule PidroServerWeb.API.ClassicClaimControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.{ClassicClaims, ClassicClaimTicket, Token, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  test "a Classic claim links only a new account or a guest it registers", %{conn: conn} do
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    for mode <- [:new, :upgrade, :existing, :guest_result] do
      owner = AccountsFixtures.user_fixture()

      caller =
        case mode do
          :new -> nil
          :existing -> AccountsFixtures.user_fixture()
          _ -> AccountsFixtures.guest_fixture()
        end

      attrs = %{
        classic_user_id: System.unique_integer([:positive]),
        method: if(mode == :guest_result, do: :apple, else: :password),
        provider_id: if(mode == :guest_result, do: "guest-apple"),
        legacy_data: %{}
      }

      attrs =
        if caller,
          do: Map.put(attrs, :user_id, caller.id),
          else: Map.put(attrs, :install_id, "link-claim")

      {:ok, ticket} = ClassicClaims.issue_ticket(attrs)

      params = %{
        ticket: ticket.ticket,
        install_id: "link-claim",
        friend_slug: owner.share_slug,
        account: %{username: "claim_#{mode}", email: "#{mode}@example.com", password: "secret123"},
        age_band: "18_plus",
        terms_version: "1"
      }

      request =
        if caller,
          do: put_req_header(conn, "authorization", "Bearer #{Token.generate(caller)}"),
          else: conn

      data =
        request
        |> post(~p"/api/v1/classic/claim", params)
        |> json_response(200)
        |> Map.fetch!("data")

      id = data["user"]["id"]
      owner_id = owner.id

      # An Apple claim registers the guest too (:guest_result).
      if mode in [:new, :upgrade, :guest_result] do
        assert %{friends: [], requested: [%{user_id: ^owner_id}]} = PidroServer.Friends.list(id)

        assert %{friends: [], added_you: [%{user_id: ^id}]} =
                 PidroServer.Friends.list(owner_id)

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

        {:ok, _} = PidroServer.Friends.remove(id, owner_id)

        retry_conn =
          if caller,
            do: put_req_header(conn, "authorization", "Bearer #{data["token"]}"),
            else: conn

        retry =
          retry_conn
          |> post(~p"/api/v1/classic/claim", params)
          |> json_response(200)
          |> Map.fetch!("data")

        refute Map.has_key?(retry, "linked_friend")
        assert %{friends: [], added_you: []} = PidroServer.Friends.list(owner_id)
      else
        refute Map.has_key?(data, "linked_friend")
        assert %{friends: [], added_you: []} = PidroServer.Friends.list(owner_id)
      end

      refute_received {:friend_event, _, _, _}
    end
  end

  test "verifies Classic ownership and returns a user-bound preview ticket", %{conn: conn} do
    guest = AccountsFixtures.guest_fixture()

    Req.Test.expect(PidroServer.Accounts.ClassicClient, fn classic_conn ->
      {:ok, body, classic_conn} = Plug.Conn.read_body(classic_conn)

      assert Jason.decode!(body) == %{
               "login" => "old@example.com",
               "password" => "classic-password"
             }

      # Real /internal/claims/verify_password payload shape (pidro_api).
      Req.Test.json(classic_conn, %{
        "classic" => %{
          "id" => 70_000,
          "username" => "Veteran",
          "member_since" => "2011-01-02T00:00:00Z",
          "xp" => 500,
          "level" => 14,
          "games" => %{"legacy_played_games" => 0, "total_game" => 88}
        }
      })
    end)

    data =
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
      |> post(~p"/api/v1/classic/verify", %{
        method: "password",
        login: "old@example.com",
        password: "classic-password"
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert is_binary(data["ticket"])
    assert is_binary(data["expires_at"])
    assert Map.fetch!(data, "already_claimed") == nil

    assert data["classic"] == %{
             "name" => "Veteran",
             "games_played" => 88,
             "level" => 14,
             "member_since" => "2011-01-02T00:00:00Z",
             "name_allowed" => true,
             "new_account" => %{"username" => "Veteran", "email" => nil}
           }

    assert Repo.get_by!(PidroServer.Accounts.ClassicClaimTicket, classic_user_id: 70_000).bound_user_id ==
             guest.id
  end

  describe "a signed-out Classic password claim" do
    setup %{conn: conn} do
      Req.Test.expect(PidroServer.Accounts.ClassicClient, fn classic_conn ->
        Req.Test.json(classic_conn, %{
          "classic" => %{
            "id" => 70_301,
            "username" => "tiger",
            "email" => "sonja@example.com",
            "level" => 1,
            "games" => %{"total_game" => 6814}
          }
        })
      end)

      response =
        conn
        |> post(~p"/api/v1/classic/verify", %{
          method: "password",
          login: "tiger",
          password: "classic-password",
          install_id: "signed-out-install"
        })
        |> json_response(200)

      {:ok, verified: response}
    end

    test "offers Classic's username and email and asks only for a password", ctx do
      %{conn: conn, verified: verified} = ctx

      OpenApiSpex.TestAssertions.assert_schema(
        verified,
        "Classic ownership verification response",
        PidroServerWeb.ApiSpec.spec()
      )

      assert verified["data"]["classic"]["new_account"] ==
               %{"username" => "tiger", "email" => "sonja@example.com"}

      user =
        conn
        |> post(~p"/api/v1/classic/claim", %{
          ticket: verified["data"]["ticket"],
          install_id: "signed-out-install",
          account: %{password: "secret123"}
        })
        |> json_response(200)
        |> get_in(["data", "user"])

      assert user["username"] == "tiger"
      assert Repo.get!(User, user["id"]).email == "sonja@example.com"
    end

    test "still accepts an older client's username, email and password", ctx do
      %{conn: conn, verified: verified} = ctx

      user =
        conn
        |> post(~p"/api/v1/classic/claim", %{
          ticket: verified["data"]["ticket"],
          install_id: "signed-out-install",
          account: %{username: "tiger", email: "sonja@example.com", password: "secret123"}
        })
        |> json_response(200)
        |> get_in(["data", "user"])

      assert user["username"] == "tiger"
      assert Repo.get!(User, user["id"]).classic_user_id == 70_301
    end
  end

  describe "verify of a Classic account that is already linked" do
    defp expect_classic_password(classic_id) do
      Req.Test.expect(PidroServer.Accounts.ClassicClient, fn classic_conn ->
        Req.Test.json(classic_conn, %{
          "classic" => %{
            "id" => classic_id,
            "username" => "Veteran",
            "member_since" => "2011-01-02T00:00:00Z",
            "xp" => 500,
            "level" => 14,
            "games" => %{"legacy_played_games" => 0, "total_game" => 88}
          }
        })
      end)
    end

    defp verify_password(conn, user) do
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
      |> post(~p"/api/v1/classic/verify", %{method: "password", login: "a", password: "b"})
      |> json_response(200)
      |> get_in(["data", "already_claimed"])
    end

    defp link_classic!(user, classic_id, fields) do
      user
      |> User.classic_claim_changeset(
        Map.merge(%{classic_user_id: classic_id, classic_claimed_at: DateTime.utc_now()}, fields)
      )
      |> Ecto.Changeset.change(password_hash: fields[:password_hash])
      |> Repo.update!()
    end

    test "names how the owner signs in, for password, Apple and Facebook", %{conn: conn} do
      for {classic_id, fields, method} <- [
            {70_101, %{password_hash: "hash"}, "password"},
            {70_102, %{apple_sub: "owner-apple"}, "apple"},
            {70_103, %{facebook_id: "owner-facebook"}, "facebook"}
          ] do
        link_classic!(AccountsFixtures.user_fixture(), classic_id, fields)
        expect_classic_password(classic_id)

        assert verify_password(conn, AccountsFixtures.guest_fixture()) ==
                 %{"sign_in_method" => method}
      end
    end

    test "is null when the caller owns it", %{conn: conn} do
      caller = AccountsFixtures.user_fixture()
      link_classic!(caller, 70_104, %{password_hash: "hash"})
      expect_classic_password(70_104)

      assert verify_password(conn, caller) == nil
    end
  end

  test "a malformed Apple token is a retryable authentication failure", %{conn: conn} do
    malformed =
      Base.url_encode64("1", padding: false) <>
        "." <> Base.url_encode64("{}", padding: false) <> ".AA"

    assert %{"errors" => [%{"code" => "INVALID_CREDENTIALS"}]} =
             conn
             |> post(~p"/api/v1/classic/verify", %{
               method: "apple",
               identity_token: malformed,
               install_id: "malformed-apple"
             })
             |> json_response(401)

    assert Repo.aggregate(PidroServer.Accounts.ClassicClaimTicket, :count) == 0
  end

  test "claims onto the authenticated user and returns a usable session", %{conn: conn} do
    guest = AccountsFixtures.guest_fixture()

    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_001,
        method: :apple,
        provider_id: "controller-apple-sub",
        user_id: guest.id,
        legacy_data: %{classic_user_id: 70_001, xp: 75}
      })

    data =
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
      |> post(~p"/api/v1/classic/claim", %{ticket: ticket})
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["user"]["id"] == guest.id
    assert is_binary(data["token"])
    assert Repo.get!(User, guest.id).classic_user_id == 70_001
  end

  describe "a guest claiming with a Classic password" do
    setup %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()

      {:ok, %{ticket: ticket}} =
        ClassicClaims.issue_ticket(%{
          classic_user_id: 70_201,
          method: :password,
          user_id: guest.id,
          legacy_data: %{classic_user_id: 70_201, xp: 75}
        })

      conn = put_req_header(conn, "authorization", "Bearer #{Token.generate(guest)}")
      {:ok, conn: conn, guest: guest, ticket: ticket}
    end

    test "answers 422 without email and password, and the ticket stays usable", ctx do
      %{conn: conn, guest: guest, ticket: ticket} = ctx

      errors =
        conn |> post(~p"/api/v1/classic/claim", %{ticket: ticket}) |> json_response(422)

      assert Enum.sort(Enum.map(errors["errors"], & &1["code"])) == ["email", "password"]
      assert Enum.all?(errors["errors"], &(&1["detail"] =~ "Classic account"))
      assert Repo.get!(User, guest.id).guest
      assert Repo.get!(User, guest.id).classic_user_id == nil

      account = %{email: "guest-claim@example.com", password: "secret123"}

      assert %{"data" => _} =
               conn
               |> post(~p"/api/v1/classic/claim", %{ticket: ticket, account: account})
               |> json_response(200)
    end

    test "saves the guest with a token that works", ctx do
      %{conn: conn, guest: guest, ticket: ticket} = ctx
      account = %{email: "guest-claim@example.com", password: "secret123"}

      data =
        conn
        |> post(~p"/api/v1/classic/claim", %{ticket: ticket, account: account})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["user"]["id"] == guest.id
      refute Repo.get!(User, guest.id).guest

      assert %{"data" => %{"user" => %{"id" => id}}} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{data["token"]}")
               |> get(~p"/api/v1/auth/me")
               |> json_response(200)

      assert id == guest.id

      # The same ticket again answers the existing link without the account.
      assert %{"data" => %{"user" => %{"id" => ^id}}} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{data["token"]}")
               |> post(~p"/api/v1/classic/claim", %{ticket: ticket})
               |> json_response(200)
    end

    test "refuses a taken email and links nothing", ctx do
      %{conn: conn, guest: guest, ticket: ticket} = ctx
      other = AccountsFixtures.user_fixture()
      account = %{email: other.email, password: "secret123"}

      errors =
        conn
        |> post(~p"/api/v1/classic/claim", %{ticket: ticket, account: account})
        |> json_response(422)

      assert [%{"code" => "email"}] = errors["errors"]
      assert Repo.get!(User, guest.id).guest
      assert Repo.get!(User, guest.id).classic_user_id == nil
    end
  end

  test "stores a declaration on a newly created Classic account", %{conn: conn} do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_101,
        method: :facebook,
        provider_id: "age-facebook-id",
        install_id: "age-install",
        legacy_data: %{
          classic_user_id: 70_101,
          classic_username: "Age Veteran",
          classic_name_allowed: true,
          xp: 75
        }
      })

    user =
      conn
      |> post(~p"/api/v1/classic/claim", %{
        ticket: ticket,
        install_id: "age-install",
        account: %{username: "age_veteran"},
        age_band: "18_plus",
        terms_version: "1"
      })
      |> json_response(200)
      |> get_in(["data", "user"])

    assert user["age_band"] == "18_plus"
    assert user["terms_version"] == "1"

    persisted = Repo.get!(User, user["id"])
    assert persisted.age_band == "18_plus"
    assert persisted.terms_version == "1"
    assert %DateTime{} = persisted.age_declared_at
    assert %DateTime{} = persisted.terms_accepted_at
  end

  test "refuses or validates a declaration without redeeming the Classic ticket", %{conn: conn} do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_102,
        method: :facebook,
        provider_id: "blocked-facebook-id",
        install_id: "blocked-install",
        legacy_data: %{
          classic_user_id: 70_102,
          classic_username: "Blocked Veteran",
          classic_name_allowed: true,
          xp: 75
        }
      })

    base = %{
      ticket: ticket,
      install_id: "blocked-install",
      account: %{username: "must_stay_missing"}
    }

    assert %{"errors" => [%{"code" => "AGE_NOT_ELIGIBLE"}]} =
             conn
             |> post(~p"/api/v1/classic/claim", Map.put(base, :age_band, "under_13"))
             |> json_response(403)

    assert %{"errors" => [%{"code" => "terms_version"}]} =
             build_conn()
             |> post(~p"/api/v1/classic/claim", Map.put(base, :terms_version, ""))
             |> json_response(422)

    refute Repo.get_by(User, username: "must_stay_missing")
    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 70_102).redeemed_by_id == nil
  end

  test "rejects a malformed Bearer header before touching an install-bound ticket", %{conn: conn} do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_002,
        method: :facebook,
        provider_id: "controller-facebook-id",
        install_id: "install-70",
        legacy_data: %{classic_user_id: 70_002, xp: 75}
      })

    assert json_response(
             conn
             |> put_req_header("authorization", "not-a-bearer")
             |> post(~p"/api/v1/classic/claim", %{
               ticket: ticket,
               install_id: "install-70",
               account: %{username: "must_not_exist"}
             }),
             401
           )

    refute Repo.get_by(User, username: "must_not_exist")
  end

  test "rejects a non-object account without redeeming the ticket", %{conn: conn} do
    guest = AccountsFixtures.guest_fixture(%{display_name: "Original Guest"})

    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_004,
        method: :password,
        user_id: guest.id,
        legacy_data: %{
          classic_user_id: 70_004,
          classic_username: "Classic Veteran",
          classic_name_allowed: true,
          xp: 75
        }
      })

    assert %{
             "errors" => [
               %{"code" => "account", "detail" => "must be an object"}
             ]
           } =
             conn
             |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
             |> post(~p"/api/v1/classic/claim", %{ticket: ticket, account: []})
             |> json_response(422)

    persisted = Repo.get!(User, guest.id)
    assert persisted.classic_user_id == nil
    assert persisted.display_name == "Original Guest"
    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 70_004).redeemed_by_id == nil
  end

  test "an already claimed Classic account returns the exact sign-in path", %{conn: conn} do
    owner =
      %User{}
      |> User.social_registration_changeset(%{username: "controller_owner"})
      |> Repo.insert!()

    owner
    |> User.classic_claim_changeset(%{
      classic_user_id: 70_003,
      classic_claimed_at: DateTime.utc_now(),
      apple_sub: "owner-apple-sub"
    })
    |> Repo.update!()

    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_003,
        method: :facebook,
        provider_id: "different-facebook-id",
        install_id: "install-owner",
        legacy_data: %{
          xp: 10,
          classic_username: "Fuckface",
          classic_name_allowed: false
        }
      })

    assert %{
             "errors" => [
               %{
                 "code" => "ALREADY_CLAIMED",
                 "action" => %{
                   "type" => "sign_in",
                   "method" => "apple",
                   "endpoint" => "/api/v1/auth/apple"
                 }
               }
             ]
           } =
             conn
             |> post(~p"/api/v1/classic/claim", %{
               ticket: ticket,
               install_id: "install-owner",
               account: %{username: "not_created"}
             })
             |> json_response(409)

    refute Repo.get_by(User, username: "not_created")
  end
end
