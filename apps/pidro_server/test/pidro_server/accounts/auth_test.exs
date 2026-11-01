defmodule PidroServer.Accounts.AuthTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{Auth, Token, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Invites
  alias PidroServer.Invites.{Event, Invite, Redemption}
  alias PidroServer.Profiles
  alias PidroServer.Profiles.{Achievement, PlayerProfile}
  alias PidroServer.Stats.GameStats

  defp subscribe_to_socket(user) do
    :ok = Phoenix.PubSub.subscribe(PidroServer.PubSub, "user_socket:#{user.id}")
  end

  defp fetch_for(token) do
    {:ok, claims} = Token.verify(token)
    Auth.fetch_user_for_token(claims)
  end

  # A generator that hands out the given codes in order, then falls back to
  # the real one, so a test can force a `guest_<code>` username collision.
  defp scripted_generator(codes) do
    {:ok, agent} = Agent.start_link(fn -> codes end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {Invites.Codes.generate(), []}
        [code | rest] -> {code, rest}
      end)
    end
  end

  defp seconds_ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp stamp_last_seen(user, value) do
    user |> Ecto.Changeset.change(last_seen_at: value) |> Repo.update!()
  end

  describe "register_user/1" do
    test "ignores guest in the attributes" do
      assert {:ok, user} =
               Auth.register_user(%{
                 username: "register_guest",
                 email: "register_guest@example.com",
                 password: "password123",
                 guest: true
               })

      refute user.guest
      refute Repo.get!(User, user.id).guest
    end

    test "stores a trimmed display_name" do
      assert {:ok, user} =
               Auth.register_user(%{
                 username: "register_named",
                 email: "register_named@example.com",
                 password: "password123",
                 display_name: "  Anna  "
               })

      assert user.display_name == "Anna"
    end

    test "rejects a display_name longer than 20 graphemes" do
      assert {:error, changeset} =
               Auth.register_user(%{
                 username: "register_long",
                 email: "register_long@example.com",
                 password: "password123",
                 display_name: String.duplicate("a", 21)
               })

      assert %{display_name: ["should be at most 20 character(s)"]} = errors_on(changeset)
    end

    test "a new username passes the word list, evasions included; a clean name containing a word passes" do
      for name <- ["v1ttu", "paska_peli", "kuksugare", "f_u_c_k"] do
        assert {:error, changeset} =
                 Auth.register_user(%{
                   username: name,
                   email: "#{name}@example.com",
                   password: "password123"
                 })

        assert %{username: ["is not allowed as a public name"]} = errors_on(changeset)
      end

      assert {:ok, %{username: "Kukkonen"}} =
               Auth.register_user(%{
                 username: "Kukkonen",
                 email: "kukkonen@example.com",
                 password: "password123"
               })
    end

    test "rejects blocked usernames and display names" do
      assert {:error, username_error} =
               Auth.register_user(%{
                 username: "Fuckface",
                 email: "blocked-username@example.com",
                 password: "password123"
               })

      assert %{username: ["is not allowed as a public name"]} = errors_on(username_error)

      assert {:error, display_error} =
               Auth.register_user(%{
                 username: "allowed_login",
                 display_name: "fuck face",
                 email: "blocked-display@example.com",
                 password: "password123"
               })

      assert %{display_name: ["is not allowed as a public name"]} = errors_on(display_error)
    end

    test "validates the stored username rather than a normalized display surrogate" do
      assert {:error, long_error} =
               Auth.register_user(%{
                 username: "abc" <> String.duplicate(" ", 18),
                 email: "long-raw-username@example.com",
                 password: "password123"
               })

      assert %{username: ["should be at most 20 character(s)"]} = errors_on(long_error)

      assert {:error, control_error} =
               Auth.register_user(%{
                 username: "line\nbreak",
                 email: "control-username@example.com",
                 password: "password123"
               })

      assert %{username: ["must not contain control or format characters"]} =
               errors_on(control_error)
    end
  end

  describe "create_guest_user/2" do
    test "creates a guest with a generated username, no credentials and the install id" do
      assert {:ok, %User{} = guest} =
               Auth.create_guest_user(%{display_name: "  Anna  ", install_id: "install-1"}, [])

      assert guest.guest
      assert guest.username =~ ~r/\Aguest_[0-9A-HJKMNP-TV-Z]{8}\z/
      assert guest.display_name == "Anna"
      assert guest.install_id == "install-1"
      assert is_nil(guest.email)
      assert is_nil(guest.password_hash)
      assert guest.token_version == 0

      stored = Repo.get!(User, guest.id)
      assert stored.guest
      assert stored.username == guest.username
    end

    test "accepts string-keyed attributes" do
      assert {:ok, %User{display_name: "Ben", install_id: "i-2"}} =
               Auth.create_guest_user(%{"display_name" => "Ben", "install_id" => "i-2"}, [])
    end

    test "generates a display_name when it is absent or nil" do
      assert {:ok, %User{display_name: generated}} = Auth.create_guest_user(%{}, [])
      assert generated =~ ~r/\A\S+ \S+(?: [2-9])?\z/u

      assert {:ok, %User{display_name: generated_for_nil}} =
               Auth.create_guest_user(%{display_name: nil}, [])

      assert generated_for_nil =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
    end

    test "still rejects a blank supplied display_name" do
      assert {:error, changeset} = Auth.create_guest_user(%{display_name: "  "}, [])
      assert %{display_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "applies the display-name rule" do
      assert {:error, changeset} = Auth.create_guest_user(%{display_name: "A"}, [])
      assert %{display_name: ["should be at least 2 character(s)"]} = errors_on(changeset)
    end

    test "rejects a blocked supplied display_name" do
      assert {:error, changeset} = Auth.create_guest_user(%{display_name: "Fuckface"}, [])
      assert %{display_name: ["is not allowed as a public name"]} = errors_on(changeset)
    end

    test "rejects a display_name whose key is taken at the table" do
      taken = [User.name_key("Marcel")]

      assert {:error, changeset} = Auth.create_guest_user(%{display_name: "marcél"}, taken)
      assert %{display_name: ["is already used at this table"]} = errors_on(changeset)
      assert Repo.aggregate(from(u in User, where: u.guest == true), :count) == 0
    end

    test "ignores names that are not in the taken list, so a returning guest keeps hers" do
      # Anna's first guest row exists (her seat is held); the caller only
      # passes the keys of connected seats, so a second Anna is fine.
      assert {:ok, _first} = Auth.create_guest_user(%{display_name: "Anna"}, [])

      assert {:ok, %User{display_name: "Anna"}} =
               Auth.create_guest_user(%{display_name: "Anna"}, [User.name_key("Marcel")])
    end

    test "accepts two different emoji-only names at one table" do
      # Two graphemes each: a single emoji is below the 2-grapheme minimum.
      fox = "\u{1F98A}\u{1F98A}"
      panda = "\u{1F43C}\u{1F43C}"

      assert {:ok, %User{display_name: ^fox}} = Auth.create_guest_user(%{display_name: fox}, [])

      assert {:ok, %User{display_name: ^panda}} =
               Auth.create_guest_user(%{display_name: panda}, [User.name_key(fox)])

      assert {:error, changeset} =
               Auth.create_guest_user(%{display_name: fox}, [User.name_key(fox)])

      assert %{display_name: ["is already used at this table"]} = errors_on(changeset)
    end

    test "retries once when the generated username collides" do
      AccountsFixtures.user_fixture(%{username: "guest_TAKEN123"})
      generator = scripted_generator(["TAKEN123", "FRESH123"])

      assert {:ok, %User{username: "guest_FRESH123"}} =
               Auth.create_guest_user(%{display_name: "Cid"}, [], generator: generator)
    end

    test "keeps one generated display_name while retrying a username collision" do
      AccountsFixtures.user_fixture(%{username: "guest_TAKEN123"})
      generator = scripted_generator(["TAKEN123", "FRESH123"])

      assert {:ok, %User{username: "guest_FRESH123", display_name: display_name}} =
               Auth.create_guest_user(%{}, [], generator: generator)

      assert display_name =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
    end

    test "answers the changeset error when both draws collide" do
      AccountsFixtures.user_fixture(%{username: "guest_TAKEN123"})
      AccountsFixtures.user_fixture(%{username: "guest_TAKEN456"})
      generator = scripted_generator(["TAKEN123", "TAKEN456"])

      assert {:error, changeset} =
               Auth.create_guest_user(%{display_name: "Cid"}, [], generator: generator)

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "upgrade_guest/2" do
    test "upgrades the row in place, bumps token_version once and signs the new version" do
      guest = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      {:ok, profile} = Profiles.get_or_create_profile(guest.id)
      old_token = Token.generate(guest)
      subscribe_to_socket(guest)

      assert {:ok, %User{} = upgraded} =
               Auth.upgrade_guest(guest, %{email: "anna@example.com", password: "password123"})

      assert upgraded.id == guest.id
      assert upgraded.email == "anna@example.com"
      assert upgraded.username == guest.username
      assert upgraded.display_name == "Anna"
      refute upgraded.guest
      assert upgraded.token_version == guest.token_version + 1
      assert Bcrypt.verify_pass("password123", upgraded.password_hash)

      stored = Repo.get!(User, guest.id)
      refute stored.guest
      assert stored.token_version == 1
      assert stored.email == "anna@example.com"

      assert {:error, :token_revoked} = fetch_for(old_token)
      assert {:ok, %User{token_version: 1}} = fetch_for(Token.generate(upgraded))
      assert {:ok, _} = Auth.authenticate_user("anna@example.com", "password123")

      assert Repo.get!(PlayerProfile, profile.id).user_id == guest.id
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      owner = AccountsFixtures.user_fixture()

      assert {:error, :not_a_guest} =
               Auth.upgrade_guest(guest, %{
                 email: "anna@example.com",
                 password: "password123",
                 friend_slug: owner.share_slug
               })

      assert PidroServer.Friends.list(upgraded.id).friends == []
      assert Repo.get!(User, guest.id).token_version == 1
    end

    test "applies an optional username" do
      guest = AccountsFixtures.guest_fixture()

      assert {:ok, %User{username: "anna_upgraded"}} =
               Auth.upgrade_guest(guest, %{
                 email: "anna2@example.com",
                 password: "password123",
                 username: "anna_upgraded"
               })
    end

    test "rejects a blocked optional username" do
      guest = AccountsFixtures.guest_fixture()

      assert {:error, changeset} =
               Auth.upgrade_guest(guest, %{
                 email: "blocked-upgrade@example.com",
                 password: "password123",
                 username: "Fuckface"
               })

      assert %{username: ["is not allowed as a public name"]} = errors_on(changeset)
      assert Repo.get!(User, guest.id).guest

      assert {:error, changeset} =
               Auth.upgrade_guest(guest, %{
                 email: "listed-upgrade@example.com",
                 password: "password123",
                 username: "Huora"
               })

      assert %{username: ["is not allowed as a public name"]} = errors_on(changeset)
    end

    test "accepts string-keyed attributes" do
      guest = AccountsFixtures.guest_fixture()

      assert {:ok, %User{email: "anna3@example.com", guest: false}} =
               Auth.upgrade_guest(guest, %{
                 "email" => "anna3@example.com",
                 "password" => "password123"
               })
    end

    test "answers not_a_guest for a registered user" do
      user = AccountsFixtures.user_fixture()

      assert {:error, :not_a_guest} =
               Auth.upgrade_guest(user, %{email: "x@example.com", password: "password123"})

      assert Repo.get!(User, user.id).token_version == 0
    end

    test "answers email_taken case-insensitively" do
      AccountsFixtures.user_fixture(%{email: "Taken@Example.com"})
      guest = AccountsFixtures.guest_fixture()

      assert {:error, :email_taken} =
               Auth.upgrade_guest(guest, %{email: "taken@example.com", password: "password123"})

      stored = Repo.get!(User, guest.id)
      assert stored.guest
      assert stored.token_version == 0
    end

    test "answers username_taken" do
      AccountsFixtures.user_fixture(%{username: "wanted_name"})
      guest = AccountsFixtures.guest_fixture()

      assert {:error, :username_taken} =
               Auth.upgrade_guest(guest, %{
                 email: "free@example.com",
                 password: "password123",
                 username: "wanted_name"
               })

      assert Repo.get!(User, guest.id).guest
    end

    test "answers the changeset for invalid attributes without bumping the version" do
      guest = AccountsFixtures.guest_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.upgrade_guest(guest, %{email: "nope", password: "short"})

      assert %{email: [_], password: [_]} = errors_on(changeset)

      stored = Repo.get!(User, guest.id)
      assert stored.guest
      assert stored.token_version == 0
    end
  end

  describe "delete_user/1" do
    setup do
      RoomManager.reset_for_test()
      on_exit(&PidroServer.RoomManagerCase.cleanup/0)
      :ok
    end

    test "vacates the seat, revokes hosted invites, removes personal rows and disconnects" do
      host = AccountsFixtures.user_fixture()
      user = AccountsFixtures.guest_fixture(%{display_name: "Ben"})

      # Ben hosted an invite for a table he created earlier and left (which
      # closed it); the tombstone must lose its label.
      {:ok, hosted_room} = RoomManager.create_room(user.id)
      :ok = RoomManager.leave_room(user.id)

      {:ok, room} = RoomManager.create_room(host.id)
      {:ok, room, position} = RoomManager.join_room(room.code, user.id)
      assert room.positions[position] == user.id

      {:ok, invite} =
        Invites.create_invite(%{
          room_id: hosted_room.id,
          room_code: hosted_room.code,
          host_user_id: user.id,
          seat_hint: "partner",
          label: "Anna"
        })

      {:ok, _} = Invites.record_redemption(invite, %{user_id: user.id, position: "south"})
      {:ok, _} = Invites.record_event(invite, %{kind: "guest_created", user_id: user.id})
      {:ok, _profile} = Profiles.get_or_create_profile(user.id)
      :awarded = Profiles.award_achievement(user.id, :first_game)

      %GameStats{}
      |> GameStats.changeset(%{
        room_code: room.code,
        completed_at: DateTime.truncate(DateTime.utc_now(), :second),
        player_ids: [host.id, user.id]
      })
      |> Repo.insert!()

      subscribe_to_socket(user)

      assert {:ok, %User{id: id}} = Auth.delete_user(user)
      assert id == user.id

      assert is_nil(Repo.get(User, user.id))
      {:ok, room_after} = RoomManager.get_room(room.code)
      refute user.id in Map.values(room_after.positions)

      assert %Invite{revoked_at: %DateTime{}, label: nil} = Repo.get!(Invite, invite.id)
      assert Repo.aggregate(from(r in Redemption, where: r.user_id == ^user.id), :count) == 0
      assert Repo.aggregate(from(e in Event, where: e.user_id == ^user.id), :count) == 0
      assert is_nil(Repo.get_by(PlayerProfile, user_id: user.id))
      assert is_nil(Repo.get_by(Achievement, user_id: user.id))

      assert [%GameStats{player_ids: player_ids}] = Repo.all(GameStats)
      assert user.id in player_ids

      assert_receive %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
      assert topic == "user_socket:#{user.id}"
    end

    test "recomputes invite_live_until for a live room the user hosted invites on" do
      host = AccountsFixtures.user_fixture()
      inviter = AccountsFixtures.user_fixture()

      # A room host leaving a waiting room closes it, so the live-room case
      # is a seated non-host whose invite row names them as host_user_id.
      {:ok, room} = RoomManager.create_room(host.id)
      {:ok, _room, _position} = RoomManager.join_room(room.code, inviter.id)

      {:ok, invite} =
        Invites.create_invite(%{
          room_id: room.id,
          room_code: room.code,
          host_user_id: inviter.id
        })

      :ok = RoomManager.note_invite(room.code, invite.expires_at)
      {:ok, %RoomManager.Room{invite_live_until: %DateTime{}}} = RoomManager.get_room(room.code)

      assert {:ok, _deleted} = Auth.delete_user(inviter)

      {:ok, room_after} = RoomManager.get_room(room.code)
      assert is_nil(room_after.invite_live_until)
      refute inviter.id in Map.values(room_after.positions)
      assert %Invite{revoked_at: %DateTime{}} = Repo.get!(Invite, invite.id)
    end

    test "leaves invite_live_until alone when the room code was recycled by another room" do
      host = AccountsFixtures.user_fixture()
      inviter = AccountsFixtures.user_fixture()

      {:ok, room} = RoomManager.create_room(host.id)
      {:ok, _room, _position} = RoomManager.join_room(room.code, inviter.id)

      # An invite bound to a different room id under the same code: a stale
      # row from a closed table whose code was reused.
      {:ok, _invite} =
        Invites.create_invite(%{
          room_id: Ecto.UUID.generate(),
          room_code: room.code,
          host_user_id: inviter.id
        })

      later = DateTime.add(DateTime.utc_now(), 3_600, :second)
      :ok = RoomManager.note_invite(room.code, later)

      assert {:ok, _deleted} = Auth.delete_user(inviter)

      {:ok, room_after} = RoomManager.get_room(room.code)
      assert room_after.invite_live_until == later
    end

    test "a guest creation token is free again once its guest is deleted" do
      attrs = %{display_name: "Ben", install_id: "install-1", creation_token: "token-1"}

      assert {:ok, guest, :created} = Auth.create_guest_user_once(attrs, [])
      assert {:ok, %User{id: id}, :existing} = Auth.create_guest_user_once(attrs, [])
      assert id == guest.id
      assert {:ok, _deleted} = Auth.delete_user(guest)

      assert {:ok, again, :created} = Auth.create_guest_user_once(attrs, [])
      assert again.id != guest.id
      assert again.guest
    end

    test "succeeds for a user in no room with no personal rows" do
      user = AccountsFixtures.user_fixture()
      subscribe_to_socket(user)

      assert {:ok, %User{}} = Auth.delete_user(user)
      assert is_nil(Repo.get(User, user.id))
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "removes both friendship directions and ignores without deleting unrelated ones" do
      user = AccountsFixtures.user_fixture()
      friend = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, _} = PidroServer.Friends.add(user.id, friend.id)
      {:ok, _} = PidroServer.Friends.add(friend.id, user.id)
      {:ok, _} = PidroServer.Friends.add(friend.id, other.id)
      {:ok, _} = PidroServer.Friends.add(other.id, user.id)
      {:ok, _} = PidroServer.Friends.ignore(user.id, other.id)
      {:ok, _} = PidroServer.Friends.ignore(other.id, friend.id)

      assert {:ok, %User{}} = Auth.delete_user(user)

      assert [%{user_id: user_id, friend_id: friend_id}] =
               Repo.all(PidroServer.Friends.Friendship)

      assert {user_id, friend_id} == {friend.id, other.id}

      assert [%{user_id: ignorer_id, ignored_id: ignored_id}] =
               Repo.all(PidroServer.Friends.Ignore)

      assert {ignorer_id, ignored_id} == {other.id, friend.id}
    end

    test "keeps the player's feedback as guest notes without their reply address" do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()

      {:ok, note} =
        PidroServer.Feedback.create(
          %{"kind" => "note", "body" => "Hi", "reply_email" => "me@example.com"},
          user
        )

      # No address typed in: the account's email was filled in.
      {:ok, filled} = PidroServer.Feedback.create(%{"kind" => "note", "body" => "Hey"}, user)
      assert filled.reply_email == user.email

      {:ok, kept} = PidroServer.Feedback.create(%{"kind" => "note", "body" => "Hello"}, other)

      assert {:ok, _} = Auth.delete_user(user)
      assert Repo.get!(PidroServer.Feedback.Entry, filled.id).reply_email == nil

      assert %{user_id: nil, reply_email: nil, body: "Hi"} =
               Repo.get!(PidroServer.Feedback.Entry, note.id)

      assert Repo.get!(PidroServer.Feedback.Entry, kept.id).reply_email == other.email
    end
  end

  describe "touch_last_seen/1" do
    test "writes when last_seen_at is nil" do
      user = AccountsFixtures.user_fixture()
      assert is_nil(user.last_seen_at)

      assert :ok = Auth.touch_last_seen(user)

      assert %DateTime{} = seen = Repo.get!(User, user.id).last_seen_at
      assert DateTime.diff(DateTime.utc_now(), seen, :second) < 5
    end

    test "skips a value 10 minutes old" do
      ten_minutes_ago = seconds_ago(600)
      user = stamp_last_seen(AccountsFixtures.user_fixture(), ten_minutes_ago)

      assert :ok = Auth.touch_last_seen(user.id)

      assert Repo.get!(User, user.id).last_seen_at == ten_minutes_ago
    end

    test "writes over a value 2 hours old" do
      two_hours_ago = seconds_ago(7_200)
      user = stamp_last_seen(AccountsFixtures.user_fixture(), two_hours_ago)

      assert :ok = Auth.touch_last_seen(user)

      seen = Repo.get!(User, user.id).last_seen_at
      assert DateTime.compare(seen, two_hours_ago) == :gt
    end

    test "answers ok for an unknown id" do
      assert :ok = Auth.touch_last_seen(Ecto.UUID.generate())
    end
  end

  describe "authenticate_user/2" do
    test "returns the user for valid credentials" do
      user = AccountsFixtures.user_fixture(%{username: "login_ok"})

      assert {:ok, %User{id: id}} =
               Auth.authenticate_user("login_ok", AccountsFixtures.valid_user_password())

      assert id == user.id
    end

    test "rejects a wrong password" do
      AccountsFixtures.user_fixture(%{username: "login_wrong"})

      assert {:error, :invalid_credentials} = Auth.authenticate_user("login_wrong", "nope nope")
    end

    test "rejects an unknown username" do
      assert {:error, :invalid_credentials} = Auth.authenticate_user("nobody", "password123")
    end

    test "returns invalid credentials for a user without a password hash" do
      {:ok, guest} =
        %User{}
        |> User.guest_changeset(%{username: "guest_login"})
        |> Repo.insert()

      assert is_nil(guest.password_hash)
      assert {:error, :invalid_credentials} = Auth.authenticate_user("guest_login", "anything")
    end

    test "accepts the email address as the identifier, case-insensitively" do
      user = AccountsFixtures.user_fixture(%{email: "Login.Email@Example.com"})

      assert {:ok, %User{id: id}} =
               Auth.authenticate_user(
                 "login.email@example.com",
                 AccountsFixtures.valid_user_password()
               )

      assert id == user.id

      assert {:ok, %User{id: ^id}} =
               Auth.authenticate_user(
                 "LOGIN.EMAIL@EXAMPLE.COM",
                 AccountsFixtures.valid_user_password()
               )
    end

    test "rejects an unknown email" do
      assert {:error, :invalid_credentials} =
               Auth.authenticate_user("nobody@example.com", "password123")
    end

    test "rejects the wrong password for an email identifier" do
      AccountsFixtures.user_fixture(%{email: "wrong.pw@example.com"})

      assert {:error, :invalid_credentials} =
               Auth.authenticate_user("wrong.pw@example.com", "not the password")
    end

    test "a username shaped like another user's email does not shadow that email" do
      owner = AccountsFixtures.user_fixture(%{email: "shadow@example.com"})

      {:ok, impostor} =
        Auth.register_user(%{
          username: "shadow@example.com",
          email: "impostor@example.com",
          password: "impostor pass"
        })

      assert {:ok, %User{id: id}} =
               Auth.authenticate_user(
                 "shadow@example.com",
                 AccountsFixtures.valid_user_password()
               )

      assert id == owner.id
      refute id == impostor.id

      assert {:error, :invalid_credentials} =
               Auth.authenticate_user("shadow@example.com", "impostor pass")
    end

    test "an identifier without @ never matches an email" do
      AccountsFixtures.user_fixture(%{username: "plain_name", email: "plain@example.com"})

      assert {:ok, _} =
               Auth.authenticate_user("plain_name", AccountsFixtures.valid_user_password())

      assert {:error, :invalid_credentials} =
               Auth.authenticate_user("plain", AccountsFixtures.valid_user_password())
    end
  end

  describe "change_user/2 and update_user/2" do
    test "set guest from admin attrs" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, updated} = Auth.update_user(user, %{"guest" => "true"})
      assert updated.guest
      assert Repo.get!(User, user.id).guest

      changeset = Auth.change_user(updated, %{"guest" => "false"})
      assert get_change(changeset, :guest) == false
    end

    test "still update username and email" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, updated} =
               Auth.update_user(user, %{
                 "username" => "renamed_by_admin",
                 "email" => "renamed@example.com"
               })

      assert updated.username == "renamed_by_admin"
      assert updated.email == "renamed@example.com"
    end

    test "rejects a blocked admin rename" do
      user = AccountsFixtures.user_fixture()

      assert {:error, changeset} = Auth.update_user(user, %{"username" => "Fuckface"})
      assert %{username: ["is not allowed as a public name"]} = errors_on(changeset)
    end

    test "rejects a control character in an admin rename" do
      user = AccountsFixtures.user_fixture()

      assert {:error, changeset} = Auth.update_user(user, %{"username" => "line\nbreak"})

      assert %{username: ["must not contain control or format characters"]} =
               errors_on(changeset)
    end
  end

  describe "fetch_user_for_token/1" do
    test "returns the user when the version matches" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %User{id: id, token_version: 0}} =
               Auth.fetch_user_for_token(%{id: user.id, v: 0})

      assert id == user.id
    end

    test "returns not_found for an unknown id" do
      assert {:error, :not_found} = Auth.fetch_user_for_token(%{id: Ecto.UUID.generate(), v: 0})
    end

    test "returns token_revoked when the version differs" do
      user = AccountsFixtures.user_fixture()

      assert {:error, :token_revoked} = Auth.fetch_user_for_token(%{id: user.id, v: 1})
      assert {:error, :token_revoked} = Auth.fetch_user_for_token(%{id: user.id, v: -1})
    end
  end

  describe "bump_token_version/1" do
    test "increments token_version atomically and returns the updated user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %User{token_version: 1} = bumped} = Auth.bump_token_version(user)
      assert bumped.id == user.id
      assert Repo.get!(User, user.id).token_version == 1

      assert {:ok, %User{token_version: 2}} = Auth.bump_token_version(bumped)
      assert Repo.get!(User, user.id).token_version == 2
    end

    test "accepts a bare user id" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %User{token_version: 1}} = Auth.bump_token_version(user.id)
    end

    test "returns not_found for an unknown user" do
      assert {:error, :not_found} = Auth.bump_token_version(Ecto.UUID.generate())
    end

    test "invalidates every earlier token and accepts a fresh one" do
      user = AccountsFixtures.user_fixture()
      old_token = Token.generate(user)
      assert {:ok, _} = fetch_for(old_token)

      {:ok, bumped} = Auth.bump_token_version(user)

      assert {:error, :token_revoked} = fetch_for(old_token)
      assert {:ok, %User{token_version: 1}} = fetch_for(Token.generate(bumped))
    end

    test "broadcasts disconnect on the user's socket topic after the increment" do
      user = AccountsFixtures.user_fixture()
      subscribe_to_socket(user)

      {:ok, _bumped} = Auth.bump_token_version(user)

      assert_receive %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
      assert topic == "user_socket:#{user.id}"
      assert Repo.get!(User, user.id).token_version == 1
    end

    test "does not broadcast for an unknown user" do
      id = Ecto.UUID.generate()
      :ok = Phoenix.PubSub.subscribe(PidroServer.PubSub, "user_socket:#{id}")

      assert {:error, :not_found} = Auth.bump_token_version(id)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "two concurrent bumps leave token_version incremented by exactly 2" do
      user = AccountsFixtures.user_fixture()

      # The shared sandbox serialises these on one connection, so this pins
      # the atomic `inc` rather than a read-modify-write in application code.
      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> Auth.bump_token_version(user.id) end) end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %User{}}, &1))
      assert results |> Enum.map(fn {:ok, u} -> u.token_version end) |> Enum.sort() == [1, 2]
      assert Repo.get!(User, user.id).token_version == 2
    end
  end

  describe "reset_user_password/2" do
    test "a reset token expires after the configured lifetime" do
      original = Application.fetch_env!(:pidro_server, :password_reset_ttl_seconds)
      on_exit(fn -> Application.put_env(:pidro_server, :password_reset_ttl_seconds, original) end)

      user = AccountsFixtures.user_fixture()
      {:ok, %{token: token}} = Auth.request_password_reset(user.username)

      assert {:ok, %User{}} = Auth.reset_user_password(token, "new password!")

      {:ok, %{token: token}} = Auth.request_password_reset(user.username)
      Application.put_env(:pidro_server, :password_reset_ttl_seconds, 0)

      assert {:error, :invalid_or_expired_password_reset_token} =
               Auth.reset_user_password(token, "another password!")
    end

    test "changes the password, bumps token_version and clears the reset fields together" do
      user = AccountsFixtures.user_fixture(%{username: "reset_me"})
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)
      old_token = Token.generate(user)
      subscribe_to_socket(user)

      assert {:ok, %User{} = reset} = Auth.reset_user_password(reset_token, "new password!")

      assert reset.id == user.id
      assert reset.token_version == 1
      assert is_nil(reset.password_reset_token_hash)
      assert is_nil(reset.password_reset_sent_at)
      assert Bcrypt.verify_pass("new password!", reset.password_hash)

      stored = Repo.get!(User, user.id)
      assert stored.token_version == 1
      assert is_nil(stored.password_reset_token_hash)
      assert is_nil(stored.password_reset_sent_at)
      assert {:ok, _} = Auth.authenticate_user("reset_me", "new password!")

      assert {:error, :token_revoked} = fetch_for(old_token)
      assert {:ok, %User{token_version: 1}} = fetch_for(Token.generate(reset))

      assert_receive %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
      assert topic == "user_socket:#{user.id}"
    end

    test "rejects a reused reset token" do
      user = AccountsFixtures.user_fixture()
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      assert {:ok, _} = Auth.reset_user_password(reset_token, "new password!")

      assert {:error, :invalid_or_expired_password_reset_token} =
               Auth.reset_user_password(reset_token, "another password!")

      assert Repo.get!(User, user.id).token_version == 1
    end

    test "rejects unknown or malformed tokens" do
      assert {:error, :invalid_or_expired_password_reset_token} =
               Auth.reset_user_password("nope", "new password!")

      assert {:error, :invalid_or_expired_password_reset_token} =
               Auth.reset_user_password(nil, "new password!")
    end

    test "rolls back the whole transaction when the password is invalid" do
      user = AccountsFixtures.user_fixture()
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)
      subscribe_to_socket(user)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.reset_user_password(reset_token, "short")

      assert %{password: [_message]} = errors_on(changeset)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      stored = Repo.get!(User, user.id)
      assert stored.token_version == 0
      refute is_nil(stored.password_reset_token_hash)

      assert {:ok, %User{token_version: 1}} =
               Auth.reset_user_password(reset_token, "long enough now!")
    end
  end

  describe "user_fixture/1" do
    test "keeps the email when flipping guest" do
      user = AccountsFixtures.user_fixture(%{guest: true, email: "g@x.test"})

      assert user.guest
      assert user.email == "g@x.test"

      stored = Repo.get!(User, user.id)
      assert stored.guest
      assert stored.email == "g@x.test"
    end

    test "builds a non-guest by default" do
      user = AccountsFixtures.user_fixture()

      refute user.guest
      assert is_binary(user.password_hash)
    end
  end
end
