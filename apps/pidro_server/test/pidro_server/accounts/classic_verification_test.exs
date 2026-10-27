defmodule PidroServer.Accounts.ClassicVerificationTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Accounts.{ClassicClaims, ClassicClaimTicket, ClassicVerification, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  defmodule Classic do
    @behaviour PidroServer.Accounts.ClassicClient

    @impl true
    def verify_password("veteran@example.com", "correct-password"), do: {:ok, profile()}

    def verify_password("disjoint-counters", "correct-password") do
      {:ok, Map.merge(profile(), %{"played_games" => 100, "total_game" => 20})}
    end

    def verify_password("blocked-name", "correct-password") do
      {:ok, Map.put(profile(), "username", "  Fuckface  ")}
    end

    # A pre-2017 veteran exactly as Classic's live endpoint describes one,
    # passed through the real client's normalizer.
    def verify_password("bengt@example.com", "correct-password") do
      {:ok,
       PidroServer.Accounts.ClassicClient.normalize(%{
         "id" => 50,
         "username" => nil,
         "first_name" => "Bengt",
         "email" => "bengt@example.com",
         "member_since" => "2014-03-02T10:00:00",
         "level" => 1,
         "xp" => 0,
         "games" => %{
           "legacy_played_games" => 1862,
           "legacy_victories" => 937,
           "legacy_losses" => 925,
           "total_game" => 0,
           "win_game" => 0,
           "lost_game" => 0,
           "games_logged" => 0,
           "games_started" => 0,
           "games_ended" => 0
         },
         "premium" => %{"active" => false, "until" => nil},
         "friend_ids" => [12, 345],
         "friended_by_ids" => [67],
         "blocked_ids" => [89],
         "badges" => []
       })}
    end

    # Classic recorded no creation date before about 2018 (live id 2000, 2026-10-16).
    def verify_password("tiger", "correct-password") do
      {:ok,
       PidroServer.Accounts.ClassicClient.normalize(%{
         "id" => 2000,
         "username" => "tiger",
         "first_name" => "sonja",
         "member_since" => nil,
         "level" => 1,
         "xp" => 0,
         "games" => %{
           "total_game" => 6814,
           "win_game" => 3416,
           "lost_game" => 3398,
           "games_ended" => 0,
           "games_logged" => 0,
           "games_started" => 0,
           "legacy_losses" => 3394,
           "legacy_played_games" => 6806,
           "legacy_victories" => 3412
         },
         "premium" => %{"active" => false, "until" => nil},
         "account" => %{"visible" => true, "deleted" => false},
         "badges" => ["00000000000"]
       })}
    end

    def verify_password(_login, _password), do: {:error, :invalid_credentials}

    @impl true
    def lookup(:email, "apple@example.com"), do: {:ok, profile()}
    def lookup(:fbid, "current-app-id"), do: {:error, :not_found}
    def lookup(:fbid, "direct-current-app-id"), do: {:ok, profile()}
    def lookup(:fbid, "old-app-id"), do: {:ok, profile()}
    def lookup(:email, "facebook@example.com"), do: {:ok, profile()}
    def lookup(:email, "ambiguous@example.com"), do: {:error, :ambiguous}

    def lookup(:email, "deleted@example.com"),
      do: {:ok, Map.put(profile(), "account_deleted", true)}

    def lookup(:email, "sparse@example.com"), do: {:ok, %{"id" => 98_765}}

    def lookup(:email, "mf252@example.com"),
      do: {:ok, mf252(25_201)}

    def lookup(:fbid, "mf252-app-id"),
      do: {:ok, mf252(25_202)}

    def lookup(_field, _value), do: {:error, :not_found}

    # PID-301: Marcel's Classic account, reached by Apple email or Facebook id.
    defp mf252(id),
      do:
        Map.merge(profile(), %{"id" => id, "username" => "mf252", "email" => "mf252@example.com"})

    defp profile do
      %{
        "id" => 12_345,
        "username" => "",
        "firstname" => "Old Timer",
        "inserted_at" => "2012-04-03T00:00:00Z",
        "xp" => 800_000,
        "level" => 87,
        "played_games" => 40,
        "victories" => 21,
        "losses" => 19,
        "total_game" => 321,
        "win_game" => 200,
        "lost_game" => 121,
        "xpoints_count" => 250,
        "started" => 300,
        "ended" => 290,
        "badges" => ["Veteran"]
      }
    end
  end

  defmodule Providers do
    def apple("apple-token"),
      do:
        {:ok,
         %{
           "sub" => "apple-subject",
           "aud" => "com.oneapps.pidro",
           "email" => "apple@example.com",
           "email_verified" => "true"
         }}

    def apple("unverified-apple-token"),
      do:
        {:ok,
         %{
           "sub" => "apple-subject",
           "email" => "apple@example.com",
           "email_verified" => false
         }}

    def apple("missing-verification-apple-token"),
      do: {:ok, %{"sub" => "apple-subject", "email" => "apple@example.com"}}

    def apple("sparse-profile-token"),
      do:
        {:ok,
         %{
           "sub" => "apple-subject",
           "email" => "sparse@example.com",
           "email_verified" => true
         }}

    def apple("mf252-apple-token"),
      do:
        {:ok,
         %{
           "sub" => "mf252-apple-subject",
           "email" => "mf252@example.com",
           "email_verified" => true
         }}

    def apple(_token), do: {:error, :invalid_credentials}

    def facebook("facebook-token") do
      {:ok, %{subject: "current-app-id", issuer_app: "facebook-app", email: nil}}
    end

    def facebook("direct-facebook-token") do
      {:ok, %{subject: "direct-current-app-id", issuer_app: "facebook-app", email: nil}}
    end

    def facebook("email-facebook-token") do
      {:ok,
       %{
         subject: "email-current-app-id",
         issuer_app: "facebook-app",
         email: "facebook@example.com"
       }}
    end

    def facebook("mf252-facebook-token") do
      {:ok, %{subject: "mf252-app-id", issuer_app: "facebook-app", email: nil}}
    end

    def facebook(_token), do: {:error, :invalid_credentials}

    def facebook_limited("limited-token", "limited-nonce") do
      {:ok,
       %{
         subject: "limited-current-app-id",
         issuer_app: "facebook-app",
         email: "facebook@example.com"
       }}
    end

    def facebook_limited("ambiguous-token", "limited-nonce") do
      {:ok,
       %{
         subject: "limited-current-app-id",
         issuer_app: "facebook-app",
         email: "ambiguous@example.com"
       }}
    end

    def facebook_limited("deleted-token", "limited-nonce") do
      {:ok,
       %{
         subject: "limited-current-app-id",
         issuer_app: "facebook-app",
         email: "deleted@example.com"
       }}
    end

    def facebook_business_ids("facebook-token"), do: {:ok, ["old-app-id"]}
    def facebook_business_ids("direct-facebook-token"), do: {:ok, ["unused-old-app-id"]}
    def facebook_business_ids("email-facebook-token"), do: {:ok, []}
    def facebook_business_ids("mf252-facebook-token"), do: {:ok, []}
  end

  test "a real Classic payload for a no-username veteran previews name and old games" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "bengt@example.com",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic.name == "Bengt"
    assert result.classic.games_played == 1862
    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 50)
    assert ticket.bound_user_id == user.id
    assert ticket.legacy_data["friend_ids"] == [12, 345]
    assert ticket.legacy_data["friended_by_ids"] == [67]
    assert ticket.legacy_data["blocked_ids"] == [89]
  end

  describe "a password claim's new account" do
    defp verify_bengt(user, params \\ %{}) do
      ClassicVerification.verify(
        Map.merge(
          %{
            "method" => "password",
            "login" => "bengt@example.com",
            "password" => "correct-password"
          },
          params
        ),
        user,
        classic_client: Classic,
        provider_identity: Providers
      )
    end

    test "takes Classic's email, and leaves a missing username to the player" do
      assert {:ok, result} = verify_bengt(nil, %{"install_id" => "bengt-install"})

      assert result.classic.name == "Bengt"
      assert result.classic.new_account == %{username: nil, email: "bengt@example.com"}

      assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 50).legacy_data["new_account"] ==
               %{"username" => nil, "email" => "bengt@example.com"}
    end

    test "offers no email another Pidro account uses" do
      AccountsFixtures.user_fixture(email: "Bengt@Example.com")

      assert {:ok, result} = verify_bengt(AccountsFixtures.guest_fixture())
      assert result.classic.new_account == %{username: nil, email: nil}
    end

    test "is absent for a signed-in player, who keeps their own account" do
      assert {:ok, result} = verify_bengt(AccountsFixtures.user_fixture())
      refute Map.has_key?(result.classic, :new_account)

      refute Map.has_key?(
               Repo.get_by!(ClassicClaimTicket, classic_user_id: 50).legacy_data,
               "new_account"
             )
    end
  end

  describe "a signed-out Apple or Facebook claim's new account" do
    defp verify_mf252(method, user \\ nil)

    defp verify_mf252(:apple, user) do
      ClassicVerification.verify(
        %{
          "method" => "apple",
          "identity_token" => "mf252-apple-token",
          "install_id" => "mf252-install"
        },
        user,
        classic_client: Classic,
        provider_identity: Providers
      )
    end

    defp verify_mf252(:facebook, user) do
      ClassicVerification.verify(
        %{
          "method" => "facebook",
          "access_token" => "mf252-facebook-token",
          "install_id" => "mf252-install"
        },
        user,
        classic_client: Classic,
        provider_identity: Providers
      )
    end

    test "takes Classic's username and no email, and needs no account on redeem" do
      for method <- [:apple, :facebook] do
        assert {:ok, result} = verify_mf252(method)
        assert result.classic.new_account == %{username: "mf252", email: nil}

        assert {:ok, created} =
                 ClassicClaims.redeem(result.ticket, nil, %{"install_id" => "mf252-install"})

        assert {created.username, created.guest} == {"mf252", false}
        Repo.delete!(created)
      end
    end

    test "keeps Classic's username over what an old client sends" do
      assert {:ok, result} = verify_mf252(:facebook)

      assert {:ok, created} =
               ClassicClaims.redeem(result.ticket, nil, %{
                 install_id: "mf252-install",
                 account: %{username: "typed_name", email: "typed@example.com"}
               })

      assert {created.username, created.email, created.facebook_id} ==
               {"mf252", nil, "mf252-app-id"}
    end

    test "offers no username another Pidro account has, and still needs one" do
      AccountsFixtures.user_fixture(username: "mf252")

      assert {:ok, result} = verify_mf252(:apple)
      assert result.classic.new_account == %{username: nil, email: nil}

      params = %{install_id: "mf252-install"}
      assert {:error, changeset} = ClassicClaims.redeem(result.ticket, nil, params)
      assert %{username: ["can't be blank"]} = errors_on(changeset)
      assert Repo.get_by(User, classic_user_id: 25_201) == nil

      params = Map.put(params, :account, %{username: "mf_252"})
      assert {:ok, created} = ClassicClaims.redeem(result.ticket, nil, params)
      assert created.username == "mf_252"
    end

    test "is absent for a guest, who keeps their username, and a signed-in player" do
      assert {:ok, result} = verify_mf252(:facebook, AccountsFixtures.user_fixture())
      refute Map.has_key?(result.classic, :new_account)

      guest = AccountsFixtures.guest_fixture()

      assert {:ok, result} = verify_mf252(:apple, guest)
      refute Map.has_key?(result.classic, :new_account)

      refute Map.has_key?(
               Repo.get_by!(ClassicClaimTicket, classic_user_id: 25_201).legacy_data,
               "new_account"
             )

      assert {:ok, claimed} = ClassicClaims.redeem(result.ticket, guest, %{})
      assert {claimed.id, claimed.username} == {guest.id, guest.username}
    end
  end

  test "an account from before Classic recorded dates previews with no member_since" do
    assert {:ok, result} =
             ClassicVerification.verify(
               %{"method" => "password", "login" => "tiger", "password" => "correct-password"},
               AccountsFixtures.guest_fixture(),
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic.name == "tiger"
    assert result.classic.member_since == nil
    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 2000)
  end

  test "password verification accepts an email login and binds the authenticated user" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "veteran@example.com",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic == %{
             name: "Old Timer",
             games_played: 321,
             level: 87,
             member_since: "2012-04-03T00:00:00Z",
             name_allowed: true,
             new_account: %{username: nil, email: nil}
           }

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.bound_user_id == user.id
    assert ticket.install_id == nil
    assert ticket.method == :password
    assert ticket.matched_on == :password
    assert ticket.legacy_data["classic_username"] == "Old Timer"
    assert ticket.legacy_data["classic_name_allowed"] == true
    assert ticket.legacy_data["games_played_counter"] == 321
  end

  test "a blocked Classic name is preserved privately and marked unavailable" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "blocked-name",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic.name == "  Fuckface  "
    assert result.classic.name_allowed == false

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.legacy_data["classic_username"] == "  Fuckface  "
    assert ticket.legacy_data["classic_name_allowed"] == false
  end

  test "preview uses the same disjoint-era game count as the claimed profile" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "disjoint-counters",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic.games_played == 120
  end

  test "Apple proof resolves Classic by email but stores only the stable subject" do
    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "apple",
                 "identity_token" => "apple-token",
                 "install_id" => "apple-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.install_id == "apple-install"
    assert ticket.method == :apple
    assert ticket.matched_on == :email
    assert ticket.provider_id == "apple-subject"
    assert ticket.provider_issuer_app == "com.oneapps.pidro"
    assert ticket.provider_email == "apple@example.com"
    refute inspect(ticket.legacy_data) =~ "apple@example.com"
    assert result.classic.new_account == %{username: nil, email: nil}
  end

  test "Facebook checks every business-scoped id and keeps the current app id" do
    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "access_token" => "facebook-token",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.method == :facebook
    assert ticket.matched_on == :facebook_business_id
    assert ticket.provider_id == "current-app-id"
    assert result.classic.new_account == %{username: nil, email: nil}
  end

  test "Facebook records a match on the current app id" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "access_token" => "direct-facebook-token",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.matched_on == :facebook_id
  end

  test "Facebook falls back to verified email" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "access_token" => "email-facebook-token",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345).matched_on == :email
  end

  test "Facebook Limited Login verifies a Classic claim by email" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "authentication_token" => "limited-token",
                 "nonce" => "limited-nonce",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.provider_id == "limited-current-app-id"
    assert ticket.provider_business_ids == []
    assert ticket.matched_on == :email
  end

  test "ambiguous or deleted Facebook emails are not a Classic match" do
    for token <- ["ambiguous-token", "deleted-token"] do
      assert {:error, :invalid_credentials} =
               ClassicVerification.verify(
                 %{
                   "method" => "facebook",
                   "authentication_token" => token,
                   "nonce" => "limited-nonce",
                   "install_id" => "facebook-install"
                 },
                 nil,
                 classic_client: Classic,
                 provider_identity: Providers
               )
    end

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "Facebook requires exactly one credential shape" do
    for params <- [
          %{"method" => "facebook", "install_id" => "facebook-install"},
          %{
            "method" => "facebook",
            "access_token" => "facebook-token",
            "authentication_token" => "limited-token",
            "nonce" => "limited-nonce",
            "install_id" => "facebook-install"
          }
        ] do
      assert {:error, :invalid_credentials} =
               ClassicVerification.verify(params, nil,
                 classic_client: Classic,
                 provider_identity: Providers
               )
    end
  end

  test "Apple email must be verified before it can select a Classic account" do
    for token <- ["unverified-apple-token", "missing-verification-apple-token"] do
      assert {:error, :invalid_credentials} =
               ClassicVerification.verify(
                 %{
                   "method" => "apple",
                   "identity_token" => token,
                   "install_id" => "apple-install"
                 },
                 nil,
                 classic_client: Classic,
                 provider_identity: Providers
               )
    end

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "a malformed Classic profile cannot issue a schema-invalid ticket" do
    assert {:error, :provider_unavailable} =
             ClassicVerification.verify(
               %{
                 "method" => "apple",
                 "identity_token" => "sparse-profile-token",
                 "install_id" => "apple-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "invalid proof and an unbound fresh install issue no ticket" do
    assert {:error, :invalid_credentials} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "veteran@example.com",
                 "password" => "wrong",
                 "install_id" => "install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert {:error, :claim_binding_required} =
             ClassicVerification.verify(
               %{
                 "method" => "apple",
                 "identity_token" => "apple-token"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end
end
