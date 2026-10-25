defmodule PidroServer.Accounts.ClassicClaimsTest do
  use PidroServer.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PidroServer.Accounts.{
    Auth,
    ClassicClaims,
    ClassicClaimTicket,
    ClassicNameReservation,
    ClassicNameReservations,
    ProviderAuth,
    User,
    UserIdentity
  }

  alias PidroServer.AccountsFixtures
  alias PidroServer.{Blocks, ClassicSocial, Friends}
  alias PidroServer.Blocks.Block
  alias PidroServer.Friends.Friendship
  alias PidroServer.Invites
  alias PidroServer.Invites.Event
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo

  defmodule ProviderIdentity do
    def apple("valid-apple-token"), do: {:ok, %{"sub" => "apple-subject"}}
    def apple(_token), do: {:error, :invalid_credentials}

    def facebook("valid-facebook-token") do
      {:ok, %{subject: "facebook-subject", issuer_app: "facebook-app", email: nil}}
    end

    def facebook(_token), do: {:error, :invalid_credentials}
    def facebook_business_ids("valid-facebook-token"), do: {:ok, []}
  end

  describe "already_claimed/3" do
    test "is nil for a free Classic account and for the caller's own" do
      user = AccountsFixtures.user_fixture()
      assert ClassicClaims.already_claimed(10_900, :password, user.id) == nil

      link!(user, 10_900, %{})
      assert ClassicClaims.already_claimed(10_900, :password, user.id) == nil
    end

    test "names how another player signs in, and nothing else" do
      for {id, method, fields} <- [
            {10_901, :password, %{password_hash: "hash"}},
            {10_902, :apple, %{password_hash: nil, apple_sub: "owner-apple"}},
            {10_903, :facebook, %{password_hash: nil, facebook_id: "owner-facebook"}}
          ] do
        link!(AccountsFixtures.user_fixture(), id, fields)

        assert ClassicClaims.already_claimed(id, :password, Ecto.UUID.generate()) ==
                 %{sign_in_method: method}
      end
    end
  end

  defp link!(user, classic_user_id, fields) do
    user
    |> User.classic_claim_changeset(
      Map.merge(
        %{classic_user_id: classic_user_id, classic_claimed_at: DateTime.utc_now()},
        Map.take(fields, [:apple_sub, :facebook_id])
      )
    )
    |> Ecto.Changeset.change(Map.take(fields, [:password_hash]))
    |> Repo.update!()
  end

  describe "Classic social import" do
    test "stores all directions, resolves claimed friends and keeps missing friends as facts" do
      a = AccountsFixtures.user_fixture()
      b = link!(AccountsFixtures.user_fixture(), 20_002, %{})
      incoming = link!(AccountsFixtures.user_fixture(), 20_003, %{})
      blocked = link!(AccountsFixtures.user_fixture(), 20_004, %{})

      ticket =
        issue_ticket!(a, 20_001, :password, nil, %{
          friend_ids: [20_002, 20_002, 20_004, 20_005],
          friended_by_ids: [20_002, 20_003, 20_004],
          blocked_ids: [20_004, 20_006]
        })

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
      assert {:ok, claimed} = ClassicClaims.redeem(ticket, a, %{})
      assert_receive {:friends_changed, id} when id == b.id
      refute_received {:friend_event, _, _, _}

      assert Enum.sort(classic_edges("classic_friendships", :classic_friend_id)) == [
               {20_001, 20_002},
               {20_001, 20_004},
               {20_001, 20_005},
               {20_002, 20_001},
               {20_003, 20_001},
               {20_004, 20_001}
             ]

      assert Enum.sort(classic_edges("classic_blocks", :classic_blocked_id)) == [
               {20_001, 20_004},
               {20_001, 20_006}
             ]

      assert Enum.map(Friends.list(a.id).friends, & &1.user_id) == [b.id]
      assert Enum.map(Friends.list(b.id).friends, & &1.user_id) == [a.id]
      assert Enum.map(Friends.list(a.id).added_you, & &1.user_id) == [incoming.id]
      assert Friends.list(incoming.id).added_you == []
      assert Friends.list(a.id).classic == %{not_here: 1}
      assert Enum.map(Blocks.list(a.id).blocked, & &1.user_id) == [blocked.id]
      assert Repo.aggregate(Friendship, :count) == 3

      assert {:ok, _} = ClassicClaims.redeem(ticket, claimed, %{})
      assert :ok = ClassicSocial.resolve_classic(claimed)
      assert Repo.aggregate(Friendship, :count) == 3
      assert Repo.aggregate(Block, :count) == 1
      assert length(classic_edges("classic_friendships", :classic_friend_id)) == 6

      {:ok, _} = Friends.remove(a.id, b.id)
      {:ok, _} = Blocks.unblock(a.id, blocked.id)
      assert {:ok, _} = ClassicClaims.redeem(ticket, claimed, %{})
      another = issue_ticket!(claimed, 20_001, :password, nil, %{friend_ids: [20_002]})
      assert {:ok, _} = ClassicClaims.redeem(another, claimed, %{})
      assert Friends.list(a.id).friends == []
      assert Blocks.list(a.id).blocked == []
    end

    test "the second claim resolves stored edges even when its older ticket has no arrays" do
      a = AccountsFixtures.user_fixture()
      b = AccountsFixtures.user_fixture()

      first =
        issue_ticket!(a, 20_010, :password, nil, %{
          friend_ids: [20_011],
          friended_by_ids: [20_011]
        })

      second = issue_ticket!(b, 20_011, :password, nil, %{})

      assert {:ok, _} = ClassicClaims.redeem(first, a, %{})
      assert Friends.list(a.id).friends == []
      assert Friends.list(a.id).classic.not_here == 1
      assert {:ok, _} = ClassicClaims.redeem(second, b, %{})
      assert Enum.map(Friends.list(a.id).friends, & &1.user_id) == [b.id]
      assert Enum.map(Friends.list(b.id).friends, & &1.user_id) == [a.id]
      assert Friends.list(a.id).classic.not_here == 0
    end

    test "incoming Classic blocks and existing live blocks win over friendship in both directions" do
      for source <- [:classic, :live] do
        a = AccountsFixtures.user_fixture()
        b = AccountsFixtures.user_fixture()
        base = if source == :classic, do: 20_020, else: 20_030
        b_ticket = issue_ticket!(b, base + 1, :password, nil, %{})
        assert {:ok, _} = ClassicClaims.redeem(b_ticket, b, %{})
        {:ok, _} = Friends.add(a.id, b.id)
        {:ok, _} = Friends.add(b.id, a.id)

        case source do
          :classic -> ClassicSocial.store(base + 1, %{blocked_ids: [base]})
          :live -> Blocks.block(b.id, a.id)
        end

        ticket =
          issue_ticket!(a, base, :password, nil, %{
            friend_ids: [base + 1],
            friended_by_ids: [base + 1]
          })

        assert {:ok, _} = ClassicClaims.redeem(ticket, a, %{})
        assert Blocks.blocked?(a.id, b.id)
        refute Repo.exists?(from f in Friendship, where: f.user_id in ^[a.id, b.id])
        assert Enum.map(Blocks.list(b.id).blocked, & &1.user_id) == [a.id]
      end
    end

    test "old tickets without arrays store no social facts" do
      a = AccountsFixtures.user_fixture()
      ticket = issue_ticket!(a, 20_040, :password, nil, %{xp: 10})
      assert {:ok, _} = ClassicClaims.redeem(ticket, a, %{})
      assert classic_edges("classic_friendships", :classic_friend_id) == []
      assert classic_edges("classic_blocks", :classic_blocked_id) == []
    end

    test "resolve failure is loud, preserves the claim and facts, and the mix task recovers" do
      a = AccountsFixtures.user_fixture()
      b = link!(AccountsFixtures.user_fixture(), 20_051, %{})
      ticket = issue_ticket!(a, 20_050, :password, nil, %{friend_ids: [20_051]})
      event = [:pidro_server, :classic_social, :resolve, :error]
      handler = "classic-social-test"

      :telemetry.attach(
        handler,
        event,
        fn event, measurements, metadata, pid ->
          send(pid, {event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Repo.query!("""
      CREATE FUNCTION fail_classic_friendship() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'social storage unavailable';
      END
      $$ LANGUAGE plpgsql
      """)

      Repo.query!(
        "CREATE TRIGGER fail_classic_friendship BEFORE INSERT ON friendships " <>
          "FOR EACH ROW EXECUTE FUNCTION fail_classic_friendship()"
      )

      assert capture_log(fn ->
               assert {:ok, claimed} = ClassicClaims.redeem(ticket, a, %{})
               assert claimed.classic_user_id == 20_050
             end) =~ "Classic social resolution failed for classic_user_id=20050"

      assert_receive {^event, %{count: 1}, %{classic_user_id: 20_050, reason: _}}
      assert Repo.get!(User, a.id).classic_user_id == 20_050
      assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 20_050).redeemed_by_id == a.id

      assert Repo.get_by!(PlayerProfile, user_id: a.id).heritage_flags["classic_user_id"] ==
               20_050

      assert classic_edges("classic_friendships", :classic_friend_id) == [{20_050, 20_051}]
      assert Repo.aggregate(Friendship, :count) == 0

      Repo.query!("DROP TRIGGER fail_classic_friendship ON friendships")

      assert ExUnit.CaptureIO.capture_io(fn ->
               Mix.Tasks.Pidro.ResolveClassicSocial.run(["20050"])
               Mix.Tasks.Pidro.ResolveClassicSocial.run([])
             end) =~ "Classic social resolution complete"

      assert Enum.map(Friends.list(b.id).added_you, & &1.user_id) == [a.id]
      assert Repo.aggregate(Friendship, :count) == 1
    end
  end

  defp classic_edges(table, field) do
    Repo.all(from e in table, select: {e.classic_user_id, field(e, ^field)})
  end

  test "an authenticated guest keeps its identity and progress, and retry is a no-op" do
    guest = AccountsFixtures.guest_fixture()
    {:ok, profile} = Profiles.get_or_create_profile(guest.id)

    profile
    |> PlayerProfile.changeset(%{veteran_xp: 125, rating_mu: 31.5, games_played: 7})
    |> Repo.update!()

    ticket = issue_ticket!(guest, 10_001, :apple, "apple-subject", %{xp: 400})

    assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{})
    assert claimed.id == guest.id
    refute claimed.guest
    assert claimed.classic_user_id == 10_001
    assert claimed.classic_claim_method == :apple
    assert claimed.classic_matched_on == :email
    assert claimed.apple_sub == "apple-subject"
    assert %DateTime{} = claimed.classic_claimed_at

    identity = Repo.get_by!(UserIdentity, provider: :apple, subject: "apple-subject")
    assert identity.user_id == guest.id
    assert identity.link_source == :claim

    imported = Repo.get_by!(PlayerProfile, user_id: guest.id)
    assert imported.veteran_xp == 525
    assert imported.rating_mu == 31.5
    assert imported.games_played == 7
    claimed_at = claimed.classic_claimed_at

    assert {:ok, retried} = ClassicClaims.redeem(ticket, claimed, %{})
    assert retried.id == guest.id
    assert retried.classic_claimed_at == claimed_at
    assert Repo.get_by!(PlayerProfile, user_id: guest.id).veteran_xp == 525

    assert {:ok, signed_in} =
             ProviderAuth.authenticate(:apple, "valid-apple-token", %{},
               provider_identity: ProviderIdentity
             )

    assert signed_in.id == guest.id
  end

  test "a blocked Classic name requires a replacement without losing the claim or career" do
    guest = AccountsFixtures.guest_fixture(%{display_name: "Random Guest"})

    assert {:ok, _} =
             ClassicNameReservations.import([%{id: 10_002, username: "Fuckface"}])

    ticket =
      issue_ticket!(guest, 10_002, :password, nil, %{
        xp: 250,
        classic_username: "Fuckface",
        classic_name_allowed: false,
        classic_level: 42,
        games_played_counter: 99
      })

    assert {:error, changeset} = ClassicClaims.redeem(ticket, guest, %{})
    assert %{display_name: ["can't be blank"]} = errors_on(changeset)
    assert Repo.get!(User, guest.id).classic_user_id == nil
    assert Repo.get_by(PlayerProfile, user_id: guest.id) == nil

    assert {:ok, claimed} =
             ClassicClaims.redeem(ticket, guest, %{
               account: %{
                 display_name: "Kind Player",
                 email: "kind@example.com",
                 password: "secret123"
               }
             })

    assert claimed.id == guest.id
    assert claimed.display_name == "Kind Player"
    assert claimed.classic_user_id == 10_002

    profile = Repo.get_by!(PlayerProfile, user_id: guest.id)
    assert profile.veteran_xp == 250
    assert profile.heritage_flags["classic_username"] == "Fuckface"
    assert profile.heritage_flags["classic_name_allowed"] == false
    assert Repo.get!(ClassicNameReservation, 10_002).username == "Fuckface"
    refute Map.has_key?(Profiles.public_profile(guest.id).classic, :name)

    assert {:ok, retried} =
             ClassicClaims.redeem(ticket, claimed, %{
               account: %{display_name: "Fuckface"}
             })

    assert retried.display_name == "Kind Player"
  end

  test "both directions of the one-to-one link reject transfer" do
    first = AccountsFixtures.user_fixture()
    second = AccountsFixtures.user_fixture()

    first_ticket = issue_ticket!(first, 20_001, :password, nil, %{xp: 10})
    assert {:ok, first} = ClassicClaims.redeem(first_ticket, first, %{})

    same_classic = issue_ticket!(second, 20_001, :password, nil, %{xp: 20})

    assert {:error, {:already_claimed, :password}} =
             ClassicClaims.redeem(same_classic, second, %{})

    assert Repo.get!(User, second.id).classic_user_id == nil

    other_classic = issue_ticket!(first, 20_002, :password, nil, %{xp: 20})
    assert {:error, :user_already_claimed} = ClassicClaims.redeem(other_classic, first, %{})
    assert Repo.get!(User, first.id).classic_user_id == 20_001
  end

  test "already claimed errors name a sign-in method the owner actually has" do
    owner =
      %User{}
      |> User.social_registration_changeset(%{username: "apple_owner"})
      |> Repo.insert!()

    claimant = AccountsFixtures.user_fixture()
    owner_ticket = issue_ticket!(owner, 20_003, :apple, "owner-apple", %{xp: 10})
    assert {:ok, _owner} = ClassicClaims.redeem(owner_ticket, owner, %{})

    facebook_ticket = issue_ticket!(claimant, 20_003, :facebook, "claimant-facebook", %{xp: 10})

    assert {:error, {:already_claimed, :apple}} =
             ClassicClaims.redeem(facebook_ticket, claimant, %{})
  end

  test "a new ticket for the same pair cannot change heritage or overwrite a provider" do
    user = AccountsFixtures.user_fixture()
    first_ticket = issue_ticket!(user, 25_001, :apple, "original-sub", %{xp: 100})
    assert {:ok, claimed} = ClassicClaims.redeem(first_ticket, user, %{})

    {:ok, %{ticket: retry_ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 25_001,
        method: :password,
        user_id: user.id,
        legacy_data: %{classic_user_id: 999_999, xp: 900}
      })

    assert {:ok, retried} =
             ClassicClaims.redeem(retry_ticket, claimed, %{
               account: %{display_name: "Fuckface"}
             })

    assert retried.classic_claimed_at == claimed.classic_claimed_at
    assert retried.display_name == claimed.display_name

    profile = Repo.get_by!(PlayerProfile, user_id: user.id)
    assert profile.veteran_xp == 100
    assert profile.heritage_flags["classic_user_id"] == 25_001

    replacement = issue_ticket!(retried, 25_001, :apple, "replacement-sub", %{xp: 500})
    assert {:error, :provider_already_linked} = ClassicClaims.redeem(replacement, retried, %{})
    assert Repo.get!(User, user.id).apple_sub == "original-sub"
  end

  test "an import conflict rolls the link and provider identity back" do
    user = AccountsFixtures.user_fixture(%{display_name: "Original Player"})
    {:ok, _profile} = Profiles.import_legacy_progression(user, %{classic_user_id: 30_001, xp: 10})
    ticket = issue_ticket!(user, 30_002, :facebook, "facebook-subject", %{xp: 20})

    assert {:error, :user_already_claimed} =
             ClassicClaims.redeem(ticket, user, %{
               account: %{display_name: "Changed Player"}
             })

    persisted = Repo.get!(User, user.id)
    assert persisted.classic_user_id == nil
    assert persisted.facebook_id == nil
    assert persisted.display_name == "Original Player"

    profile = Repo.get_by!(PlayerProfile, user_id: user.id)
    assert profile.veteran_xp == 10
    assert profile.heritage_flags["classic_user_id"] == 30_001

    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 30_002).redeemed_by_id == nil
  end

  test "a fresh password claim creates one recoverable registered account" do
    ticket =
      issue_install_ticket!("fresh-password", 40_001, :password, nil, %{
        xp: 50,
        classic_username: "Fuckface",
        classic_name_allowed: false
      })

    params = %{
      install_id: "fresh-password",
      account: %{
        username: "returning_veteran",
        display_name: "Returning Veteran",
        email: "veteran@example.com",
        password: "password123"
      }
    }

    assert {:ok, created} = ClassicClaims.redeem(ticket, nil, params)
    refute created.guest
    assert upgrades() == []
    assert created.display_name == "Returning Veteran"
    assert created.classic_user_id == 40_001
    assert {:ok, signed_in} = Auth.authenticate_user("veteran@example.com", "password123")
    assert signed_in.id == created.id

    assert {:ok, retried} = ClassicClaims.redeem(ticket, nil, params)
    assert retried.id == created.id
  end

  test "a fresh social claim binds repeat sign-in without inventing an email" do
    ticket =
      issue_install_ticket!("fresh-facebook", 50_001, :facebook, "facebook-subject", %{
        xp: 25,
        classic_username: "  Social   Veteran  ",
        classic_name_allowed: true
      })

    assert {:ok, created} =
             ClassicClaims.redeem(ticket, nil, %{
               install_id: "fresh-facebook",
               account: %{username: "social_veteran"}
             })

    refute created.guest
    assert created.display_name == "Social Veteran"
    assert created.email == nil
    assert created.facebook_id == "facebook-subject"

    assert Repo.get_by!(PlayerProfile, user_id: created.id).heritage_flags[
             "classic_username"
           ] == "  Social   Veteran  "

    assert {:ok, signed_in} =
             ProviderAuth.authenticate(:facebook, "valid-facebook-token", %{},
               provider_identity: ProviderIdentity
             )

    assert signed_in.id == created.id
  end

  test "a verified owner may take a reserved name and wins a colliding reservation" do
    assert {:ok, %{collisions: 1}} =
             ClassicNameReservations.import([
               %{id: 55_001, username: "Shared Veteran"},
               %{id: 55_002, username: " shared   veteran "}
             ])

    first_ticket =
      issue_install_ticket!("first-owner", 55_001, :password, nil, %{xp: 25})

    assert {:ok, first} =
             ClassicClaims.redeem(first_ticket, nil, %{
               install_id: "first-owner",
               account: %{
                 username: "SHARED VETERAN",
                 email: "first-owner@example.com",
                 password: "password123"
               }
             })

    assert first.classic_user_id == 55_001

    second_ticket =
      issue_install_ticket!("second-owner", 55_002, :password, nil, %{xp: 25})

    assert {:error, %Ecto.Changeset{} = changeset} =
             ClassicClaims.redeem(second_ticket, nil, %{
               install_id: "second-owner",
               account: %{
                 username: " shared   veteran ",
                 email: "second-owner@example.com",
                 password: "password123"
               }
             })

    assert %{
             username: [
               "This name belongs to a Classic player. Claim your Classic profile or choose another name."
             ]
           } = errors_on(changeset)

    refute Repo.get_by(User, email: "second-owner@example.com")

    assert {:ok, second} =
             ClassicClaims.redeem(second_ticket, nil, %{
               install_id: "second-owner",
               account: %{
                 username: "second_veteran",
                 display_name: "Second Veteran",
                 email: "second-owner@example.com",
                 password: "password123"
               }
             })

    assert second.classic_user_id == 55_002
    assert second.display_name == "Second Veteran"
  end

  test "expiry and binding failures leave the user untouched" do
    user = AccountsFixtures.user_fixture()

    {:ok, %{ticket: expired}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 60_001,
        method: :password,
        user_id: user.id,
        legacy_data: %{xp: 100}
      })

    ClassicClaimTicket
    |> Repo.get_by!(classic_user_id: 60_001)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :claim_ticket_expired} = ClassicClaims.redeem(expired, user, %{})
    assert Repo.get!(User, user.id).classic_user_id == nil

    install_ticket =
      issue_install_ticket!("right-install", 60_002, :facebook, "other-subject", %{xp: 100})

    assert {:error, :claim_ticket_binding_mismatch} =
             ClassicClaims.redeem(install_ticket, nil, %{
               install_id: "wrong-install",
               account: %{username: "never_created"}
             })

    refute Repo.get_by(User, username: "never_created")
  end

  test "a ticket expires after the configured lifetime" do
    key = PidroServer.Accounts.ClassicClaims
    original = Application.fetch_env!(:pidro_server, key)
    on_exit(fn -> Application.put_env(:pidro_server, key, original) end)
    Application.put_env(:pidro_server, key, ticket_ttl_seconds: 0)

    guest = AccountsFixtures.user_fixture()
    ticket = issue_ticket!(guest, 40_001, :password, nil, %{xp: 1})

    assert {:error, :claim_ticket_expired} = ClassicClaims.redeem(ticket, guest, %{})
  end

  describe "a guest claiming by password" do
    setup do
      {:ok, guest: AccountsFixtures.guest_fixture()}
    end

    test "must set an email and password, and nothing is linked without them", %{guest: guest} do
      ticket = issue_ticket!(guest, 50_001, :password, nil, %{xp: 90})

      assert {:error, changeset} = ClassicClaims.redeem(ticket, guest, %{})
      assert %{email: [_], password: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               ClassicClaims.redeem(ticket, guest, %{account: %{email: "a@example.com"}})

      assert %{password: [_]} = errors_on(changeset)
      refute Map.has_key?(errors_on(changeset), :email)

      unchanged = Repo.get!(User, guest.id)
      assert unchanged.guest
      assert is_nil(unchanged.classic_user_id)
      assert is_nil(unchanged.email)
      assert Repo.get_by(PlayerProfile, user_id: guest.id) == nil

      account = %{email: "a@example.com", password: "secret123"}
      assert {:ok, _claimed} = ClassicClaims.redeem(ticket, guest, %{account: account})
    end

    test "is saved in place and signs in with the new credentials", %{guest: guest} do
      ticket = issue_ticket!(guest, 50_002, :password, nil, %{xp: 90})
      account = %{"email" => "Saved@Example.com", "password" => "secret123"}

      assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{"account" => account})
      assert claimed.id == guest.id
      refute claimed.guest
      assert claimed.username == guest.username
      assert claimed.token_version == guest.token_version + 1
      assert claimed.classic_user_id == 50_002

      assert {:ok, signed_in} = Auth.authenticate_user("Saved@Example.com", "secret123")
      assert signed_in.id == guest.id
      assert Repo.get_by!(PlayerProfile, user_id: guest.id).veteran_xp == 90

      assert {:ok, retried} = ClassicClaims.redeem(ticket, claimed, %{})
      assert retried.id == guest.id
      assert Repo.aggregate(PlayerProfile, :count) == 1
    end

    test "counts once as an upgrade on the invite the guest came through", %{guest: guest} do
      invite = invite_redeemed_by!(guest)
      ticket = issue_ticket!(guest, 50_010, :password, nil, %{xp: 90})
      account = %{email: "saved@example.com", password: "secret123"}

      assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{account: account})
      assert {:ok, _retried} = ClassicClaims.redeem(ticket, claimed, %{})

      assert [%Event{invite_id: invite_id, user_id: user_id}] = upgrades()
      assert {invite_id, user_id} == {invite.id, guest.id}
    end

    test "is not failed by a failed upgrade event", %{guest: guest} do
      invite_redeemed_by!(guest)
      fail_event_inserts!()
      ticket = issue_ticket!(guest, 50_011, :password, nil, %{xp: 90})
      account = %{email: "saved@example.com", password: "secret123"}

      log =
        capture_log(fn ->
          assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{account: account})
          refute claimed.guest
        end)

      assert log =~ "guest_upgraded event failed for #{guest.id}"
      assert upgrades() == []
      refute Repo.get!(User, guest.id).guest
    end

    test "is refused when the email is taken", %{guest: guest} do
      other = AccountsFixtures.user_fixture()
      ticket = issue_ticket!(guest, 50_003, :password, nil, %{xp: 90})
      account = %{email: String.upcase(other.email), password: "secret123"}

      assert {:error, changeset} = ClassicClaims.redeem(ticket, guest, %{account: account})
      assert %{email: ["has already been taken"]} = errors_on(changeset)
      assert upgrades() == []

      unchanged = Repo.get!(User, guest.id)
      assert unchanged.guest
      assert is_nil(unchanged.classic_user_id)
    end

    test "may take its own Classic name as username, not another's", %{guest: guest} do
      assert {:ok, _result} =
               ClassicNameReservations.import([
                 %{id: 50_006, username: "Own Name"},
                 %{id: 50_007, username: "Other Name"}
               ])

      ticket = issue_ticket!(guest, 50_006, :password, nil, %{xp: 90})
      account = %{email: "own@example.com", password: "secret123"}

      assert {:error, changeset} =
               ClassicClaims.redeem(ticket, guest, %{
                 account: Map.put(account, :username, "Other Name")
               })

      assert %{username: [_]} = errors_on(changeset)

      assert {:ok, claimed} =
               ClassicClaims.redeem(ticket, guest, %{
                 account: Map.put(account, :username, "Own Name")
               })

      assert claimed.username == "Own Name"
    end

    test "waits for the name lock on a new username", %{guest: guest} do
      assert {:ok, _result} =
               ClassicNameReservations.import([
                 %{id: 50_008, username: "Shared Name"},
                 %{id: 50_009, username: "shared name"}
               ])

      ticket = issue_ticket!(guest, 50_008, :password, nil, %{xp: 90})
      test_pid = self()

      # Another claim holds the lock on this name in its own transaction.
      holder =
        spawn_link(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            "classic-name:shared name"
          ])

          send(test_pid, :locked)
          receive do: (:release -> :ok)
        end)

      assert_receive :locked
      Repo.query!("SET LOCAL lock_timeout = '100ms'")

      assert_raise Postgrex.Error, ~r/lock timeout/, fn ->
        ClassicClaims.redeem(ticket, guest, %{
          account: %{email: "shared@example.com", password: "secret123", username: "Shared Name"}
        })
      end

      send(holder, :release)
    end

    test "is not asked for credentials with an Apple ticket", %{guest: guest} do
      ticket = issue_ticket!(guest, 50_004, :apple, "apple-50004", %{xp: 90})

      assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{})
      assert is_nil(claimed.email)
    end
  end

  describe "a guest claiming with Apple or Facebook" do
    setup do
      {:ok, guest: AccountsFixtures.guest_fixture()}
    end

    # Since PID-154 a guest cannot sit with strangers; a veteran who signs in
    # with Apple or Facebook must not be treated as one.
    test "is saved: no longer a guest, with a share link", %{guest: guest} do
      for {method, classic_id} <- [apple: 50_020, facebook: 50_021] do
        guest = if method == :apple, do: guest, else: AccountsFixtures.guest_fixture()
        assert is_nil(guest.share_slug)
        ticket = issue_ticket!(guest, classic_id, method, "#{method}-#{classic_id}", %{xp: 90})

        assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{})
        assert claimed.id == guest.id
        refute claimed.guest
        assert is_binary(claimed.share_slug)
        assert %User{guest: false, share_slug: slug} = Repo.get!(User, guest.id)
        assert slug == claimed.share_slug
      end
    end

    # A second request that authenticated before the first committed still
    # carries the guest struct; the upgrade must count once.
    test "counts once as an upgrade, even for a stale second request", %{guest: guest} do
      invite = invite_redeemed_by!(guest)
      ticket = issue_ticket!(guest, 50_022, :apple, "apple-50022", %{xp: 90})

      assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{})
      assert {:ok, again} = ClassicClaims.redeem(ticket, guest, %{})
      assert again.id == claimed.id

      assert [%Event{invite_id: invite_id}] = upgrades()
      assert invite_id == invite.id
    end
  end

  describe "new_account/3" do
    test "offers Classic's username and email when they are valid and free" do
      assert ClassicClaims.new_account(%{"username" => " tiger ", "email" => "s@example.com"}, 1) ==
               %{username: "tiger", email: "s@example.com"}

      for {username, email} <- [{nil, nil}, {"", "not-an-email"}, {"Fuckface", 7}, {"ab", ""}] do
        assert ClassicClaims.new_account(%{"username" => username, "email" => email}, 1) ==
                 %{username: nil, email: nil}
      end
    end

    test "offers nothing another account has, except to that account" do
      other = AccountsFixtures.user_fixture()
      classic = %{"username" => other.username, "email" => String.upcase(other.email)}

      assert ClassicClaims.new_account(classic, 1) == %{username: nil, email: nil}

      assert ClassicClaims.new_account(classic, 1, other) ==
               %{username: other.username, email: String.upcase(other.email)}
    end

    test "a Classic name is free to its own Classic account only" do
      assert {:ok, _result} =
               ClassicNameReservations.import([%{id: 60_010, username: "Reserved Tiger"}])

      assert %{username: "Reserved Tiger"} =
               ClassicClaims.new_account(%{"username" => "Reserved Tiger"}, 60_010)

      assert %{username: nil} =
               ClassicClaims.new_account(%{"username" => "Reserved Tiger"}, 60_011)
    end
  end

  describe "a password claim offered Classic's username and email" do
    @offer %{username: "tiger", email: "sonja@example.com"}

    test "creates a signed-out player's account from only a password" do
      ticket = offer_ticket!(%{install_id: "only-password"}, 60_001, @offer)

      assert {:ok, created} =
               ClassicClaims.redeem(ticket, nil, %{
                 "install_id" => "only-password",
                 "account" => %{"password" => "secret123"}
               })

      assert {created.username, created.email} == {"tiger", "sonja@example.com"}
      assert {:ok, signed_in} = Auth.authenticate_user("tiger", "secret123")
      assert signed_in.id == created.id
    end

    test "saves a guest from only a password" do
      guest = AccountsFixtures.guest_fixture()
      ticket = offer_ticket!(%{user_id: guest.id}, 60_002, @offer)

      assert {:ok, claimed} =
               ClassicClaims.redeem(ticket, guest, %{account: %{password: "secret123"}})

      assert claimed.id == guest.id
      refute claimed.guest
      assert {claimed.username, claimed.email} == {"tiger", "sonja@example.com"}
      assert {:ok, %User{id: id}} = Auth.authenticate_user("sonja@example.com", "secret123")
      assert id == guest.id
    end

    test "keeps them over what an old or edited request sends" do
      ticket = offer_ticket!(%{install_id: "old-client"}, 60_003, @offer)

      assert {:ok, created} =
               ClassicClaims.redeem(ticket, nil, %{
                 install_id: "old-client",
                 account: %{
                   username: "other_name",
                   email: "other@example.com",
                   password: "secret123"
                 }
               })

      assert {created.username, created.email} == {"tiger", "sonja@example.com"}
    end

    test "lets a player without a Classic username choose one" do
      offer = %{username: nil, email: "bengt@example.com"}
      ticket = offer_ticket!(%{install_id: "no-username"}, 60_004, offer)
      params = %{install_id: "no-username", account: %{password: "secret123"}}

      assert {:error, changeset} = ClassicClaims.redeem(ticket, nil, params)
      assert %{username: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, created} =
               ClassicClaims.redeem(ticket, nil, put_in(params.account[:username], "bengt_1914"))

      assert {created.username, created.email} == {"bengt_1914", "bengt@example.com"}
    end

    test "answers the field error when an offered value was taken since verify" do
      username_ticket = offer_ticket!(%{install_id: "taken-name"}, 60_005, @offer)
      email_ticket = offer_ticket!(%{install_id: "taken-email"}, 60_006, @offer)
      AccountsFixtures.user_fixture(username: "tiger")

      assert {:error, changeset} =
               ClassicClaims.redeem(username_ticket, nil, %{
                 install_id: "taken-name",
                 account: %{password: "secret123"}
               })

      assert %{username: ["has already been taken"]} = errors_on(changeset)

      Repo.delete_all(from(u in User, where: u.username == "tiger"))
      AccountsFixtures.user_fixture(email: "sonja@example.com")

      assert {:error, changeset} =
               ClassicClaims.redeem(email_ticket, nil, %{
                 install_id: "taken-email",
                 account: %{password: "secret123"}
               })

      assert %{email: ["has already been taken"]} = errors_on(changeset)
      assert Repo.get_by(User, classic_user_id: 60_006) == nil
    end
  end

  test "a saved account claiming by password is unchanged" do
    user = AccountsFixtures.user_fixture()
    ticket = issue_ticket!(user, 50_005, :password, nil, %{xp: 90})

    assert {:ok, claimed} = ClassicClaims.redeem(ticket, user, %{})
    assert claimed.email == user.email
    assert claimed.password_hash == user.password_hash
  end

  defp invite_redeemed_by!(user) do
    {:ok, invite} =
      Invites.create_invite(%{
        room_id: Ecto.UUID.generate(),
        room_code: "K7QP",
        host_user_id: Ecto.UUID.generate()
      })

    {:ok, _redemption} = Invites.record_redemption(invite, %{user_id: user.id, position: "south"})
    invite
  end

  defp upgrades, do: Repo.all(from(e in Event, where: e.kind == "guest_upgraded"))

  # Every invite event insert fails as if its invite were gone; the sandbox
  # rolls the trigger back with the test.
  defp fail_event_inserts! do
    Repo.query!("""
    CREATE FUNCTION fail_invite_event() RETURNS trigger AS $$
    BEGIN
      RAISE foreign_key_violation USING CONSTRAINT = 'invite_events_invite_id_fkey';
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER fail_invite_event BEFORE INSERT ON invite_events " <>
        "FOR EACH ROW EXECUTE FUNCTION fail_invite_event()"
    )
  end

  defp issue_ticket!(user, classic_user_id, method, provider_id, legacy_data) do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: classic_user_id,
        method: method,
        provider_id: provider_id,
        user_id: user.id,
        legacy_data: Map.put(legacy_data, :classic_user_id, classic_user_id)
      })

    ticket
  end

  defp offer_ticket!(binding, classic_user_id, new_account) do
    {:ok, %{ticket: ticket}} =
      binding
      |> Map.merge(%{
        classic_user_id: classic_user_id,
        method: :password,
        new_account: new_account,
        legacy_data: %{classic_user_id: classic_user_id, xp: 10}
      })
      |> ClassicClaims.issue_ticket()

    ticket
  end

  defp issue_install_ticket!(install_id, classic_user_id, method, provider_id, legacy_data) do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: classic_user_id,
        method: method,
        provider_id: provider_id,
        install_id: install_id,
        legacy_data: Map.put(legacy_data, :classic_user_id, classic_user_id)
      })

    ticket
  end
end
