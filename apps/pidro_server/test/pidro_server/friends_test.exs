defmodule PidroServer.FriendsTest do
  use PidroServer.DataCase, async: false

  import PidroServer.AccountsFixtures
  alias PidroServer.Friends
  alias PidroServer.Friends.Friendship
  alias PidroServer.Games.RoomManager
  alias PidroServer.Stats.GameStats
  alias PidroServerWeb.Presence

  test "link signup sends the owner a request; nothing when the owner ignored the newcomer" do
    a = user_fixture()
    b = user_fixture()
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    assert {:ok, linked} = Friends.link_signup({:ok, a}, b.share_slug)
    assert %{user_id: b_id, join_as: nil} = linked.linked_friend
    assert b_id == b.id
    assert %{friends: [], requested: [%{user_id: ^b_id}]} = Friends.list(a.id)
    assert %{friends: [], added_you: [%{user_id: a_id}]} = Friends.list(b.id)
    assert a_id == a.id
    assert_receive {:friend_event, ^b_id, "friend_request", %{player: %{user_id: ^a_id}}}
    refute_received {:friend_event, ^a_id, _, _}

    {:ok, _} = Friends.ignore(b.id, a.id)
    {:ok, _} = Friends.remove(a.id, b.id)
    assert {:ok, unlinked} = Friends.link_signup({:ok, a}, b.share_slug)
    assert unlinked.linked_friend == nil
    assert Repo.aggregate(Friendship, :count) == 0
    refute_received {:friend_event, _, _, _}
  end

  test "link signup accepts the owner's own request, once" do
    a = user_fixture()
    b = user_fixture()
    {:ok, room} = RoomManager.create_room(b.id, %{})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    {:ok, _} = Friends.add(b.id, a.id)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    assert {:ok, linked} = Friends.link_signup({:ok, a}, b.share_slug)
    assert linked.linked_friend.user_id == b.id
    assert linked.linked_friend.join_as == "partner"
    assert Repo.aggregate(Friendship, :count) == 2
    a_id = a.id
    b_id = b.id

    assert_receive {:friend_event, ^b_id, "friend_accepted",
                    %{player: %{user_id: ^a_id}, source: "accept"}}

    refute_received {:friend_event, ^a_id, _, _}

    assert {:ok, _} = Friends.link_signup({:ok, a}, b.share_slug)
    assert Repo.aggregate(Friendship, :count) == 2
    refute_received {:friend_event, _, _, _}
  end

  test "one edge is incoming only; adding back is mutual; remove deletes both" do
    a = user_fixture()
    b = user_fixture()
    assert {:ok, %{friends: [], added_you: []}} = Friends.add(a.id, b.id)
    assert {:ok, _} = Friends.add(a.id, b.id)
    assert Repo.aggregate(Friendship, :count) == 1
    assert %{friends: [], added_you: [%{user_id: id}]} = Friends.list(b.id)
    assert id == a.id

    assert {:ok, %{friends: [%{user_id: ^id}], added_you: []}} = Friends.add(b.id, a.id)
    assert [%{user_id: other_id}] = Friends.list(a.id).friends
    assert other_id == b.id
    assert {:ok, %{friends: [], added_you: []}} = Friends.remove(a.id, b.id)

    assert Friends.list(b.id) == %{
             friends: [],
             added_you: [],
             requested: [],
             requests_waiting: 0,
             waiting_for_you: 0
           }

    assert Repo.aggregate(Friendship, :count) == 0
    assert {:ok, %{friends: [], added_you: []}} = Friends.remove(a.id, b.id)
  end

  test "a sent request is listed as requested, newest first, until cancelled" do
    caller = user_fixture()
    old = user_fixture()
    new = user_fixture()
    {:ok, _} = Friends.add(caller.id, old.id)
    {:ok, _} = Friends.add(caller.id, new.id)
    {:ok, _} = Friends.add(new.id, caller.id)
    newest = user_fixture()
    {:ok, _} = Friends.add(caller.id, newest.id)

    assert %{friends: [%{user_id: friend_id}], requested: requested} = Friends.list(caller.id)
    assert friend_id == new.id
    assert Enum.map(requested, & &1.user_id) == [newest.id, old.id]
    assert Enum.all?(requested, &match?(%DateTime{}, &1.requested_at))
    assert Friends.list(old.id).requests_waiting == 1

    assert {:ok, %{requested: [%{user_id: id}]}} = Friends.remove(caller.id, newest.id)
    assert id == old.id
  end

  test "cancel removes only the caller's edge and never an incoming request" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(b.id, a.id)

    assert {:ok, %{added_you: [%{user_id: id}], requests_waiting: 1}} = Friends.remove(a.id, b.id)
    assert id == b.id
    assert [%{user_id: ^id}] = Friends.list(a.id).added_you

    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.remove(a.id, b.id)
    assert Repo.aggregate(Friendship, :count) == 0
  end

  test "ignore hides a request from the recipient only; add back still makes friends" do
    a = user_fixture()
    b = user_fixture()
    {:ok, sender_view} = Friends.add(a.id, b.id)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    assert {:ok, %{added_you: [], requests_waiting: 0}} = Friends.ignore(b.id, a.id)
    assert_receive {:friends_changed, id} when id == b.id
    refute_received {:friends_changed, _}
    assert Friends.list(a.id) == sender_view

    assert {:ok, %{added_you: [%{user_id: id}], requests_waiting: 1}} =
             Friends.unignore(b.id, a.id)

    assert id == a.id

    {:ok, _} = Friends.ignore(b.id, a.id)
    assert {:ok, %{friends: [%{user_id: ^id}], requested: []}} = Friends.add(b.id, a.id)
    assert [%{user_id: friend_id}] = Friends.list(a.id).friends
    assert friend_id == b.id
  end

  test "an ignored request stays ignored when the sender cancels and sends it again" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.ignore(b.id, a.id)
    {:ok, _} = Friends.remove(a.id, b.id)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    assert {:ok, %{requested: [%{user_id: b_id}]}} = Friends.add(a.id, b.id)
    assert b_id == b.id
    assert %{added_you: [], requests_waiting: 0, waiting_for_you: 0} = Friends.list(b.id)
    refute_received {:friend_event, _, _, _}

    assert {:ok, %{added_you: [%{user_id: a_id}]}} = Friends.unignore(b.id, a.id)
    assert a_id == a.id
    {:ok, _} = Friends.remove(a.id, b.id)
    {:ok, _} = Friends.add(a.id, b.id)
    assert_receive {:friend_event, ^b_id, "friend_request", _}
  end

  test "answering an ignored player ends the ignore" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.ignore(b.id, a.id)
    {:ok, _} = Friends.add(b.id, a.id)
    {:ok, _} = Friends.remove(b.id, a.id)
    {:ok, _} = Friends.add(a.id, b.id)
    assert [%{user_id: id}] = Friends.list(b.id).added_you
    assert id == a.id
  end

  test "a new request tells only its receiver, with the sender's entry and last shared game" do
    a = user_fixture(%{display_name: "Pekka"})
    b = user_fixture()
    c = user_fixture()
    played = ~U[2026-10-18 19:30:00Z]
    game(a.id, [b.id], DateTime.add(played, -86_400))
    game(a.id, [b.id], played)
    game(a.id, [c.id], DateTime.add(played, 60))
    game(b.id, [c.id], DateTime.add(played, 120))
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    {:ok, _} = Friends.add(a.id, b.id)
    assert_receive {:friend_event, id, "friend_request", payload} when id == b.id

    assert payload == %{
             player: Map.delete(hd(Friends.list(b.id).added_you), :requested_at),
             played_together_at: played
           }

    assert %{user_id: sender_id, display_name: "Pekka"} = payload.player
    assert sender_id == a.id

    {:ok, _} = Friends.add(user_fixture().id, a.id)

    assert_receive {:friend_event, id, "friend_request", %{played_together_at: nil}}
                   when id == a.id

    refute_received {:friend_event, _, _, _}
  end

  test "adding back tells only the original sender, also after an ignore" do
    for ignore? <- [false, true] do
      a = user_fixture()
      b = user_fixture(%{display_name: "Nora"})
      {:ok, _} = Friends.add(a.id, b.id)
      if ignore?, do: {:ok, _} = Friends.ignore(b.id, a.id)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      {:ok, _} = Friends.add(b.id, a.id)
      assert_receive {:friend_event, id, "friend_accepted", payload} when id == a.id

      assert payload == %{
               player: Map.delete(hd(Friends.list(a.id).friends), :played_together_at),
               source: "accept"
             }

      assert payload.player.user_id == b.id
      refute_received {:friend_event, _, _, _}
      Phoenix.PubSub.unsubscribe(PidroServer.PubSub, "lobby:updates")
    end
  end

  test "repeat adds, ignore, un-ignore, cancel, remove and block tell nobody" do
    [a, b, c, d] = for _ <- 1..4, do: user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)

    for other <- [c, d] do
      {:ok, _} = Friends.add(a.id, other.id)
      {:ok, _} = Friends.add(other.id, a.id)
    end

    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.add(a.id, c.id)
    {:ok, _} = Friends.add(c.id, a.id)
    {:ok, _} = Friends.ignore(b.id, a.id)
    {:ok, _} = Friends.unignore(b.id, a.id)
    {:ok, _} = Friends.remove(a.id, b.id)
    {:ok, _} = Friends.remove(a.id, c.id)
    {:ok, _} = PidroServer.Blocks.block(a.id, d.id)

    assert_received {:friends_changed, _}
    refute_received {:friend_event, _, _, _}
  end

  test "waiting_for_you counts requests until answered and seat invitations until gone" do
    a = user_fixture()
    b = user_fixture()
    c = user_fixture()
    {:ok, _} = Friends.add(a.id, c.id)
    {:ok, _} = Friends.add(b.id, c.id)
    assert %{requests_waiting: 2, waiting_for_you: 2} = Friends.list(c.id)
    assert %{waiting_for_you: 0} = Friends.list(a.id)

    assert {:ok, %{waiting_for_you: 1}} = Friends.ignore(c.id, a.id)
    assert {:ok, %{waiting_for_you: 0}} = Friends.add(c.id, b.id)

    {:ok, room} = RoomManager.create_room(b.id, %{seat_holds: %{south: c.id}})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    assert %{requests_waiting: 0, waiting_for_you: 1} = Friends.list(c.id)

    {:ok, _} = RoomManager.set_seat_hold(room.code, b.id, :south, nil)
    assert %{waiting_for_you: 0} = Friends.list(c.id)
  end

  test "blocking clears an ignore mark with the edge" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.ignore(b.id, a.id)
    {:ok, _} = PidroServer.Blocks.block(b.id, a.id)
    {:ok, _} = PidroServer.Blocks.unblock(b.id, a.id)
    {:ok, _} = Friends.add(a.id, b.id)
    assert [%{user_id: id}] = Friends.list(b.id).added_you
    assert id == a.id
  end

  test "self, guests, missing and malformed targets are rejected without edges" do
    a = user_fixture()
    guest = guest_fixture()

    for operation <- [&Friends.add/2, &Friends.remove/2, &Friends.ignore/2, &Friends.unignore/2] do
      assert {:error, :cannot_friend_self} = operation.(a.id, a.id)

      for id <- [guest.id, Ecto.UUID.generate(), "invalid"] do
        assert {:error, :user_not_found} = operation.(a.id, id)
      end
    end

    assert Repo.aggregate(Friendship, :count) == 0
  end

  test "presence comes from lobby and game tracking; connected friends precede offline names" do
    caller = user_fixture()
    offline = user_fixture(%{display_name: "Aaron"})
    online = user_fixture(%{display_name: "Zora"})
    at_table = user_fixture(%{display_name: "Nora"})

    for user <- [offline, online, at_table] do
      {:ok, _} = Friends.add(caller.id, user.id)
      {:ok, _} = Friends.add(user.id, caller.id)
    end

    {:ok, room} = RoomManager.create_room(at_table.id, %{})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    {:ok, _} = Presence.track(self(), "lobby", online.id, %{})
    {:ok, _} = Presence.track(self(), "lobby", at_table.id, %{})
    {:ok, _} = Presence.track(self(), "game:" <> room.code, at_table.id, %{role: :player})

    assert Enum.map(Friends.list(caller.id).friends, &{&1.display_name, &1.presence}) == [
             {"Nora", "at_table"},
             {"Zora", "online"},
             {"Aaron", "offline"}
           ]

    for entry <- Friends.list(caller.id).friends, entry.presence != "at_table" do
      refute Map.has_key?(entry, :table_open_seats)
      refute Map.has_key?(entry, :table_hand)
    end
  end

  test "table facts exclude held seats and follow the deal and redeal" do
    caller = user_fixture()
    host = user_fixture(%{display_name: "Nora"})
    invited = user_fixture()
    {:ok, _} = Friends.add(caller.id, host.id)
    {:ok, _} = Friends.add(host.id, caller.id)
    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: invited.id}})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    {:ok, _} = Presence.track(self(), "game:" <> room.code, host.id, %{})

    assert [%{table_open_seats: 2, table_hand: nil}] = Friends.list(caller.id).friends
    assert {:ok, [%{table_open_seats: 2, table_hand: nil}]} = Friends.search(caller.id, "nor")
    played = ~U[2026-10-18 19:30:00Z]
    game(invited.id, [host.id], played)
    assert [%{table_open_seats: 2, table_hand: nil}] = Friends.recent(invited.id)

    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    {:ok, _} = Friends.add(host.id, invited.id)
    assert_receive {:friend_event, id, "friend_request", payload} when id == invited.id
    assert %{table_open_seats: 2, table_hand: nil} = payload.player

    {:ok, _, :south} = RoomManager.join_room(room.code, invited.id, :south)

    for position <- [:east, :west] do
      {:ok, _, ^position} = RoomManager.join_room(room.code, user_fixture().id, position)
    end

    PidroServer.RoomFixtures.ready_room(room.code)
    assert [%{table_open_seats: 0, table_hand: 1}] = Friends.list(caller.id).friends

    {:ok, snapshot} = PidroServer.Games.GameAdapter.get_snapshot(room.code)

    update = %{
      snapshot
      | state: %{snapshot.state | hand_number: 2},
        state_revision: snapshot.state_revision + 1
    }

    send(RoomManager, {:state_update, room.code, update})
    assert [%{table_open_seats: 0, table_hand: 2}] = Friends.list(caller.id).friends
  end

  test "friends carry the latest completed game shared with this viewer, or nil" do
    caller = user_fixture()
    [friend, other, never] = for _ <- 1..3, do: user_fixture()

    for user <- [friend, other, never] do
      {:ok, _} = Friends.add(caller.id, user.id)
      {:ok, _} = Friends.add(user.id, caller.id)
    end

    played = ~U[2026-10-18 19:30:00Z]
    older = DateTime.add(played, -86_400)
    game(caller.id, [friend.id, other.id], older)
    game(caller.id, [friend.id], played)
    game(friend.id, [other.id, never.id], DateTime.add(played, 60))

    assert Map.new(Friends.list(caller.id).friends, &{&1.user_id, &1.played_together_at}) == %{
             friend.id => played,
             other.id => older,
             never.id => nil
           }
  end

  test "friend rows carry level and Legend stars from one batched profile read" do
    caller = user_fixture()
    [legend, regular, newcomer] = friends = for _ <- 1..3, do: user_fixture()
    level_12_xp = Enum.at(PidroServer.Progression.thresholds(), 10)
    assert PidroServer.Progression.level_for_xp(level_12_xp) == 12

    for user <- friends do
      {:ok, _} = Friends.add(caller.id, user.id)
      {:ok, _} = Friends.add(user.id, caller.id)
    end

    for {user, xp} <- [{legend, 2_800_000}, {regular, level_12_xp}] do
      {:ok, _} = PidroServer.Profiles.get_or_create_profile(user.id)

      Repo.update_all(
        from(p in PidroServer.Profiles.PlayerProfile, where: p.user_id == ^user.id),
        set: [veteran_xp: xp]
      )
    end

    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:pidro_server, :repo, :query],
      fn _, _, meta, owner ->
        if meta.source == "player_profiles", do: send(owner, :profile_query)
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    rows = Friends.list(caller.id).friends
    assert_received :profile_query
    refute_received :profile_query

    assert Map.new(rows, &{&1.user_id, {&1.level, &1.prestige}}) == %{
             legend.id => {100, 4},
             regular.id => {12, 0},
             newcomer.id => {1, 0}
           }
  end

  test "only a started game is with bots; a table that has not started is with people" do
    caller = user_fixture()

    names =
      ~w(Solo MixedA MixedB Host PairA PairB Alone Spectator Lobby Offline)

    [solo, mixed_a, mixed_b, host, pair_a, pair_b, alone, spectator, lobby, _offline] =
      users = for name <- names, do: user_fixture(%{display_name: name})

    for user <- users do
      {:ok, _} = Friends.add(caller.id, user.id)
      {:ok, _} = Friends.add(user.id, caller.id)
    end

    solo_room = table([solo], [:east, :south, :west])
    mixed_room = table([mixed_a, mixed_b], [:south, :west])
    for room <- [solo_room, mixed_room], do: PidroServer.RoomFixtures.ready_room(room.code)
    bot_room = table([host], [:south])
    pair_room = table([pair_a, pair_b], [])
    alone_room = table([alone], [])

    for {room, user} <- [
          {solo_room, solo},
          {mixed_room, mixed_a},
          {mixed_room, mixed_b},
          {bot_room, host},
          {pair_room, pair_a},
          {pair_room, pair_b},
          {alone_room, alone},
          {solo_room, spectator}
        ] do
      {:ok, _} = Presence.track(self(), "game:" <> room.code, user.id, %{})
    end

    {:ok, _} = Presence.track(self(), "lobby", lobby.id, %{})

    presence =
      Map.new(
        Friends.list(caller.id).friends,
        &{&1.display_name, {&1.presence, &1[:table_company], &1[:table_open_seats]}}
      )

    assert presence == %{
             "Solo" => {"at_table", "bots", 0},
             "MixedA" => {"at_table", "people", 0},
             "MixedB" => {"at_table", "people", 0},
             "Host" => {"at_table", "people", 2},
             "PairA" => {"at_table", "people", 2},
             "PairB" => {"at_table", "people", 2},
             "Alone" => {"at_table", "people", 3},
             "Spectator" => {"online", nil, nil},
             "Lobby" => {"online", nil, nil},
             "Offline" => {"offline", nil, nil}
           }
  end

  test "incoming-only entries are newest first, not alphabetical" do
    caller = user_fixture()
    old = user_fixture(%{display_name: "Aaron"})
    new = user_fixture(%{display_name: "Zora"})
    {:ok, _} = Friends.add(old.id, caller.id)
    {:ok, _} = Friends.add(new.id, caller.id)
    assert Enum.map(Friends.list(caller.id).added_you, & &1.user_id) == [new.id, old.id]

    for entry <- Friends.list(caller.id).added_you do
      edge = Repo.get_by!(Friendship, user_id: entry.user_id, friend_id: caller.id)
      assert entry.requested_at == edge.inserted_at
    end
  end

  test "search uses name_key prefix, excludes self and guests, and derives all four relations" do
    caller = user_fixture(%{display_name: "Marcel Self"})
    mutual = user_fixture(%{display_name: "Márcel"})
    incoming = user_fixture(%{display_name: "ＭＡＲＣＯ"})
    outgoing = user_fixture(%{display_name: "M a r i e"})
    unrelated = user_fixture(%{display_name: "Marina"})
    guest_fixture(%{display_name: "Mar Guest"})
    user_fixture(%{display_name: "Omar"})
    {:ok, _} = Friends.add(caller.id, mutual.id)
    {:ok, _} = Friends.add(mutual.id, caller.id)
    {:ok, _} = Friends.add(incoming.id, caller.id)
    {:ok, _} = Friends.add(caller.id, outgoing.id)

    for q <- [nil, "", "ma", " é ", ["mar"]] do
      assert {:error, :query_too_short} = Friends.search(caller.id, q)
    end

    assert {:ok, entries} = Friends.search(caller.id, " ＭÁＲ ")

    assert Map.new(entries, &{&1.user_id, &1.relation}) == %{
             mutual.id => "friend",
             incoming.id => "added_you",
             outgoing.id => "added",
             unrelated.id => "none"
           }
  end

  test "a player without a display name is listed and found by username" do
    caller = user_fixture()
    plain = user_fixture(%{username: "nora_plain"})
    named = user_fixture(%{username: "nora_named", display_name: "Vera"})
    {:ok, _} = Friends.add(plain.id, caller.id)

    assert [%{user_id: id, display_name: "nora_plain"}] = Friends.list(caller.id).added_you
    assert id == plain.id

    assert {:ok, [%{display_name: "nora_plain"}]} = Friends.search(caller.id, "nora")
    assert {:ok, [%{display_name: "Vera"}]} = Friends.search(caller.id, "ver")
    assert named.display_name == "Vera"
  end

  test "search returns ten matches, not ten candidates before folding" do
    caller = user_fixture()
    for n <- 1..12, do: user_fixture(%{display_name: "Nora #{n}"})
    for n <- 1..12, do: user_fixture(%{display_name: "Aaron #{n}"})
    assert {:ok, users} = Friends.search(caller.id, "nor")
    assert length(users) == 10
    assert Enum.all?(users, &String.starts_with?(&1.display_name, "Nora"))
  end

  test "recent deduplicates humans, excludes friends and non-accounts, and limits the game window" do
    caller = user_fixture()
    friend = user_fixture()
    old = user_fixture()
    newer = user_fixture()
    newest = user_fixture()
    guest = guest_fixture()
    {:ok, _} = Friends.add(caller.id, friend.id)
    {:ok, _} = Friends.add(friend.id, caller.id)
    {:ok, _} = Friends.add(newer.id, caller.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    game(caller.id, [old.id], DateTime.add(now, -30))
    for n <- 1..19, do: game(caller.id, [friend.id], DateTime.add(now, -n))
    game(caller.id, [newest.id, newer.id, friend.id, guest.id, Ecto.UUID.generate()], now)
    game(friend.id, [old.id], DateTime.add(now, 1))

    assert Enum.map(Friends.recent(caller.id), &{&1.user_id, &1.relation}) == [
             {newest.id, "none"},
             {newer.id, "added_you"}
           ]

    game(caller.id, [newer.id, newest.id], DateTime.add(now, 2))
    assert Enum.map(Friends.recent(caller.id), & &1.user_id) == [newer.id, newest.id]
    assert Enum.all?(Friends.recent(caller.id), &(&1.played_together_at == DateTime.add(now, 2)))
    game(caller.id, [newest.id], DateTime.add(now, 3))

    assert Enum.map(Friends.recent(caller.id), &{&1.user_id, &1.played_together_at}) == [
             {newest.id, DateTime.add(now, 3)},
             {newer.id, DateTime.add(now, 2)}
           ]
  end

  test "recent returns at most ten distinct tablemates" do
    caller = user_fixture()
    users = for _ <- 1..12, do: user_fixture()
    game(caller.id, Enum.map(users, & &1.id), DateTime.utc_now() |> DateTime.truncate(:second))

    assert Enum.map(Friends.recent(caller.id), & &1.user_id) ==
             users |> Enum.take(10) |> Enum.map(& &1.id)
  end

  test "a completed table with bots suggests only the other human" do
    caller = user_fixture()
    human = user_fixture()
    alias PidroServer.Games.Room.Seat

    room = %{
      code: "BOTS",
      created_at: DateTime.utc_now(),
      seats: %{
        north: Seat.new_human(:north, caller.id),
        east: Seat.new_human(:east, human.id),
        south: Seat.new_bot(:south, self()),
        west: Seat.new_bot(:west, self())
      }
    }

    assert {:ok, _} =
             PidroServer.Stats.save_completed_game(room, :north_south, %{
               north_south: 62,
               east_west: 40
             })

    assert [%{user_id: id, relation: "none"}] = Friends.recent(caller.id)
    assert id == human.id
  end

  defp game(caller, others, completed_at) do
    %GameStats{}
    |> GameStats.changeset(%{
      room_code: "TEST",
      completed_at: completed_at,
      player_ids: [caller | others]
    })
    |> Repo.insert!()
  end

  defp table([host | guests], bot_positions) do
    {:ok, room} = RoomManager.create_room(host.id, %{})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    for guest <- guests, do: {:ok, _, :east} = RoomManager.join_room(room.code, guest.id, :east)

    for position <- bot_positions,
        do:
          {:ok, _, ^position} =
            RoomManager.join_bot(room.code, "bot_#{room.code}_#{position}", self(), position)

    room
  end
end
