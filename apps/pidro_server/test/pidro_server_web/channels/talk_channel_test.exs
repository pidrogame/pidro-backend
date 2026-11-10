defmodule PidroServerWeb.TalkChannelTest do
  @moduledoc """
  Table talk on the game channel with one real socket per person: each client
  runs in its own process, so a push reaches exactly the client it was meant
  for and the test can say who received what.
  """

  use PidroServerWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias PidroServer.AccountsFixtures
  alias PidroServer.Blocks
  alias PidroServer.Feedback
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServer.Repo
  alias PidroServerWeb.{GameChannel, UserSocket}

  @moduletag :channel

  defmodule ErrorMailer do
    use Swoosh.Adapter
    def deliver(_email, _config), do: {:error, :provider_down}
  end

  setup do
    Process.flag(:trap_exit, true)
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    adult = adult()
    adult2 = adult()
    teen = AccountsFixtures.user_fixture() |> age("13_17")
    guest = AccountsFixtures.guest_fixture()
    watcher = adult()

    {:ok, room} = RoomManager.create_room(adult.id, %{name: "Talk"})
    for user <- [adult2, teen, guest], do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    {:ok, _} = Blocks.block(adult2.id, teen.id)
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, _} = RoomManager.join_spectator_room(room.code, watcher.id)

    people = %{adult: adult, adult2: adult2, teen: teen, guest: guest, watcher: watcher}
    clients = Map.new(people, fn {name, user} -> {name, client(name, user, room.code)} end)

    %{people: people, clients: clients, room: room}
  end

  describe "talk" do
    test "a face or a word reaches every socket but the blocked pair", ctx do
      %{adult: adult, adult2: adult2, teen: teen, guest: guest} = ctx.people
      everyone = Map.keys(ctx.clients)

      assert send_talk(ctx, :adult, %{"item" => "coin_heart"}) == :ok

      assert received(ctx) ==
               for(name <- everyone, into: %{}, do: {name, [talk(:north, adult, "coin_heart")]})

      assert send_talk(ctx, :adult2, %{"item" => "word_nice"}) == :ok

      assert received(ctx) ==
               for(
                 name <- everyone -- [:teen],
                 into: %{},
                 do: {name, [talk(:east, adult2, "word_nice")]}
               )

      assert send_talk(ctx, :teen, %{"item" => "word_thanks"}) == :ok

      assert received(ctx) ==
               for(
                 name <- everyone -- [:adult2],
                 into: %{},
                 do: {name, [talk(:south, teen, "word_thanks")]}
               )

      assert send_talk(ctx, :guest, %{"item" => "coin_ha"}) == :ok

      assert received(ctx) ==
               for(name <- everyone, into: %{}, do: {name, [talk(:west, guest, "coin_ha")]})
    end

    test "a block made at the table takes effect at once, and an unblock lifts it", ctx do
      {:ok, _} = Blocks.block(ctx.people.teen.id, ctx.people.adult.id)
      assert send_talk(ctx, :adult, %{"item" => "coin_heart"}) == :ok
      refute Map.has_key?(received(ctx), :teen)

      {:ok, _} = Blocks.unblock(ctx.people.teen.id, ctx.people.adult.id)
      assert send_talk(ctx, :adult, %{"item" => "coin_heart"}) == :ok
      assert Map.has_key?(received(ctx), :teen)
    end

    test "the server names the seat and sender; a spoofed one is ignored", ctx do
      spoof = %{"item" => "coin_wow", "seat" => "west", "user_id" => ctx.people.guest.id}
      assert send_talk(ctx, :adult, spoof) == :ok

      assert %{teen: [%{seat: :north, user_id: id, item: "coin_wow"} = payload]} = received(ctx)
      assert id == ctx.people.adult.id
      assert Map.keys(payload) |> Enum.sort() == [:item, :seat, :user_id]
    end

    test "a spectator and an unknown item are refused and reach nobody", ctx do
      assert send_talk(ctx, :watcher, %{"item" => "coin_heart"}) ==
               {:error, %{error: "not_seated"}}

      assert send_talk(ctx, :adult, %{"item" => "word_rude"}) ==
               {:error, %{error: "invalid_item"}}

      assert send_talk(ctx, :adult, %{"item" => 7}) == {:error, %{error: "invalid_item"}}
      assert send_talk(ctx, :adult, %{}) == {:error, %{error: "invalid_item"}}
      assert received(ctx) == %{}
    end

    test "five in ten seconds, then the sixth is refused", ctx do
      for _ <- 1..5, do: assert(send_talk(ctx, :guest, %{"item" => "coin_thumb"}) == :ok)

      assert send_talk(ctx, :guest, %{"item" => "coin_thumb"}) ==
               {:error, %{error: "rate_limited"}}

      assert ctx |> received() |> Map.fetch!(:adult) |> length() == 5
      assert send_talk(ctx, :adult, %{"item" => "coin_thumb"}) == :ok
    end
  end

  describe "say" do
    test "a typed line reaches only seated adults who read typed talk, never a blocked pair",
         ctx do
      assert say(ctx, :adult, "  Hyvä peli!  ") == :ok

      assert received(ctx) == %{
               adult: [text(:north, ctx.people.adult, "Hyvä peli!")],
               adult2: [text(:north, ctx.people.adult, "Hyvä peli!")]
             }

      {:ok, _} = Blocks.block(ctx.people.adult2.id, ctx.people.adult.id)
      assert say(ctx, :adult, "Tack för spelet") == :ok
      assert received(ctx) == %{adult: [text(:north, ctx.people.adult, "Tack för spelet")]}
    end

    test "only an adult account may type; a teen, a guest and a spectator may not", ctx do
      assert say(ctx, :teen, "hello") == {:error, %{error: "not_allowed"}}
      assert say(ctx, :guest, "hello") == {:error, %{error: "not_allowed"}}
      assert say(ctx, :watcher, "hello") == {:error, %{error: "not_seated"}}
      for _ <- 1..5, do: assert(say(ctx, :teen, "hello") == {:error, %{error: "not_allowed"}})
      assert send_talk(ctx, :teen, %{"item" => "coin_heart"}) == :ok
      _ = received(ctx)
      assert received(ctx) == %{}
    end

    test "trimmed, 1 to 80 characters, and through the filter", ctx do
      assert say(ctx, :adult, "voi v1ttu") == {:error, %{error: "filtered"}}
      assert say(ctx, :adult, "   ") == {:error, %{error: "invalid_text"}}
      assert say(ctx, :adult, String.duplicate("ä", 81)) == {:error, %{error: "invalid_text"}}
      assert call(ctx, :adult, "say", %{"text" => 5}) == {:error, %{error: "invalid_text"}}
      assert say(ctx, :adult, "fine\n(coin_heart)") == {:error, %{error: "invalid_text"}}
      assert say(ctx, :adult, "fu\u200Bck") == {:error, %{error: "invalid_text"}}
      assert received(ctx) == %{}

      assert say(ctx, :adult, String.duplicate("ä", 80)) == :ok
      assert %{adult2: [%{text: line}]} = received(ctx)
      assert String.length(line) == 80
    end

    test "shares the talk limit", ctx do
      for _ <- 1..5, do: assert(send_talk(ctx, :adult, %{"item" => "coin_thumb"}) == :ok)
      assert say(ctx, :adult, "one more") == {:error, %{error: "rate_limited"}}
    end

    test "a report quotes the typed line the server saw", ctx do
      assert say(ctx, :adult, "learn to bid") == :ok
      assert send_talk(ctx, :adult, %{"item" => "coin_ha"}) == :ok
      report = %{"user_id" => ctx.people.adult.id, "reason" => "rude", "text" => "forged"}
      assert call(ctx, :teen, "report", report) == :ok
      assert [%{body: "learn to bid\n(coin_ha)"}] = Feedback.list("reports")
    end

    test "every seat at the table says whether its player reads typed talk, the lobby never",
         ctx do
      seats = Process.get({:reply, :watcher}).readiness.seats

      assert Map.new(seats, fn {seat, s} -> {seat, s.reads_typed} end) ==
               %{north: true, east: true, south: false, west: false}

      {:ok, room} = RoomManager.get_room(ctx.room.code)

      refute Enum.any?(PidroServerWeb.API.RoomJSON.room(room).seats, fn {_, s} ->
               Map.has_key?(s, :reads_typed)
             end)
    end
  end

  describe "a table filling up" do
    test "the host alone may talk and type; the next to sit hears it, oldest first" do
      host = adult()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Filling"})
      ctx = %{clients: %{host: client(:host, host, room.code)}}
      assert %{role: :player, position: :north, talk: []} = Process.get({:reply, :host})

      assert send_talk(ctx, :host, %{"item" => "word_hello"}) == :ok
      assert say(ctx, :host, "Moi, kuka pelaa?") == :ok
      said = [talk(:north, host, "word_hello"), text(:north, host, "Moi, kuka pelaa?")]
      assert received(ctx) == %{host: said}
      assert {:ok, %{status: :waiting}} = RoomManager.get_room(room.code)

      second = adult()
      {:ok, _, :east} = RoomManager.join_room(room.code, second.id)
      ctx = put_in(ctx.clients[:second], client(:second, second, room.code))
      assert %{position: :east} = Process.get({:reply, :second})
      assert replay(:second) == said

      assert say(ctx, :second, "Minä") == :ok
      assert received(ctx) == Map.new([:host, :second], &{&1, [text(:east, second, "Minä")]})
    end

    test "each joiner reads the earlier lines as the live push would reach them" do
      [host, other, watcher] = [adult(), adult(), adult()]
      teen = AccountsFixtures.user_fixture() |> age("13_17")
      guest = AccountsFixtures.guest_fixture()
      {:ok, _} = Blocks.block(teen.id, other.id)

      {:ok, room} = RoomManager.create_room(host.id, %{name: "Filling"})
      {:ok, _, :east} = RoomManager.join_room(room.code, other.id)

      ctx = %{
        clients: %{host: client(:host, host, room.code), other: client(:other, other, room.code)}
      }

      assert send_talk(ctx, :host, %{"item" => "word_hello"}) == :ok
      assert say(ctx, :host, "Moi") == :ok
      assert send_talk(ctx, :other, %{"item" => "coin_heart"}) == :ok
      assert say(ctx, :other, "Terve") == :ok
      items = [talk(:north, host, "word_hello"), talk(:east, other, "coin_heart")]

      # The teen blocked `other`, and reads no typed talk.
      {:ok, _, :south} = RoomManager.join_room(room.code, teen.id)
      _ = client(:teen, teen, room.code)
      assert replay(:teen) == [talk(:north, host, "word_hello")]

      {:ok, _, :west} = RoomManager.join_room(room.code, guest.id)
      _ = client(:guest, guest, room.code)
      assert replay(:guest) == items

      # An adult, but a spectator, who may watch once the game starts: items only.
      PidroServer.RoomFixtures.ready_room(room.code)
      {:ok, _} = RoomManager.join_spectator_room(room.code, watcher.id)
      _ = client(:watcher, watcher, room.code)
      assert %{role: :spectator} = Process.get({:reply, :watcher})
      assert replay(:watcher) == items
    end

    test "a host who opened the table to bots types to no one, waiting or playing" do
      host = adult()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bots"})
      for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)
      ctx = %{clients: %{host: client(:host, host, room.code)}}

      assert say(ctx, :host, "hello bots") == {:error, %{error: "no_table"}}
      assert send_talk(ctx, :host, %{"item" => "coin_heart"}) == :ok

      PidroServer.RoomFixtures.ready_room(room.code)
      assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
      assert say(ctx, :host, "hello bots") == {:error, %{error: "no_table"}}
    end

    test "once the game is on, typing needs another human again" do
      [north, south] = [adult(), adult()]
      {:ok, room} = RoomManager.create_room(north.id, %{name: "Two and two"})
      {:ok, _, _} = RoomManager.join_room(room.code, south.id, :south)
      for pos <- [:east, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)

      ctx = %{
        clients: %{
          north: client(:north, north, room.code),
          south: client(:south, south, room.code)
        }
      }

      PidroServer.RoomFixtures.ready_room(room.code)
      assert say(ctx, :north, "hello south") == :ok

      :channels_remaining = RoomManager.unregister_game_channel(room.code, south.id, self())
      Process.exit(ctx.clients.south, :kill)
      wait_for_seat(room.code, :south, &(&1 == :bot_substitute))

      assert say(ctx, :north, "anyone?") == {:error, %{error: "no_table"}}
      assert send_talk(ctx, :north, %{"item" => "coin_heart"}) == :ok
    end
  end

  describe "joining again mid-game" do
    test "a reconnect reads what was said, without the lines of a blocked player", ctx do
      assert say(ctx, :adult, "Hyvä peli") == :ok
      assert send_talk(ctx, :teen, %{"item" => "word_sorry"}) == :ok
      assert send_talk(ctx, :guest, %{"item" => "coin_ha"}) == :ok

      said = [
        text(:north, ctx.people.adult, "Hyvä peli"),
        talk(:south, ctx.people.teen, "word_sorry"),
        talk(:west, ctx.people.guest, "coin_ha")
      ]

      # adult2 blocked the teen. `ready_room` registered the test as a channel too.
      :channels_remaining =
        RoomManager.unregister_game_channel(ctx.room.code, ctx.people.adult2.id, self())

      Process.exit(ctx.clients.adult2, :kill)
      wait_for_seat(ctx.room.code, :east, &(&1 != :connected))
      _ = client(:adult2_again, ctx.people.adult2, ctx.room.code)

      assert %{reconnected: true, position: :east} = Process.get({:reply, :adult2_again})
      assert replay(:adult2_again) == List.delete_at(said, 1)

      _ = client(:adult_again, ctx.people.adult, ctx.room.code)
      assert %{reconnected: false} = Process.get({:reply, :adult_again})
      assert replay(:adult_again) == said
    end
  end

  describe "after a game" do
    test "talk ends with the game; a line said while waiting again is all a rejoin hears", ctx do
      assert say(ctx, :adult, "Hyvä peli") == :ok
      assert send_talk(ctx, :guest, %{"item" => "coin_heart"}) == :ok

      send(
        RoomManager,
        {:game_over, ctx.room.code, :north_south, %{north_south: 62, east_west: 40}}
      )

      assert {:ok, %{status: :finished}} = RoomManager.get_room(ctx.room.code)

      assert say(ctx, :adult, "Uusi peli?") == :ok
      _ = client(:adult2_again, ctx.people.adult2, ctx.room.code)

      assert [%{id: 3} = line] = Process.get({:reply, :adult2_again}).talk
      assert Map.delete(line, :id) == text(:north, ctx.people.adult, "Uusi peli?")
    end
  end

  describe "line ids" do
    test "each line takes the room's next id, alike on every push and in the replay", ctx do
      assert say(ctx, :adult, "Hyvä peli") == :ok
      assert send_talk(ctx, :teen, %{"item" => "word_sorry"}) == :ok

      ids =
        ctx |> received_raw() |> Map.new(fn {name, lines} -> {name, Enum.map(lines, & &1.id)} end)

      # adult2 blocked the teen; only adults read typed lines.
      assert ids == %{adult: [1, 2], adult2: [1], teen: [2], guest: [2], watcher: [2]}

      _ = client(:adult_again, ctx.people.adult, ctx.room.code)
      assert Enum.map(Process.get({:reply, :adult_again}).talk, & &1.id) == [1, 2]
    end

    test "a line said while someone joins reaches them once when shown by id" do
      [host, second] = [adult(), adult()]
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Filling"})
      ctx = %{clients: %{host: client(:host, host, room.code)}}
      assert say(ctx, :host, "Moi") == :ok
      {:ok, _, :east} = RoomManager.join_room(room.code, second.id)

      # Hold the room manager while the joiner subscribes and asks for the
      # room, then queue a line behind that request: it is broadcast to the
      # joiner and kept before the join reads the room again.
      manager = Process.whereis(RoomManager)
      :ok = :sys.suspend(manager)
      start_client(:second, second, room.code)
      await_call(manager, &match?({:get_room, _, :force}, &1))
      line = %{seat: :north, user_id: host.id, text: "Tule pelaamaan"}
      Task.start(fn -> RoomManager.note_talk(room.code, line) end)
      await_call(manager, &match?({:note_talk, _, _}, &1))
      :ok = :sys.resume(manager)

      assert_receive {:joined, :second, reply}, 2_000
      ctx = put_in(ctx.clients[:second], :joined)
      heard = reply.talk ++ Map.get(received_raw(ctx), :second, [])

      assert [%{id: 2} = first, %{id: 2} = again] = Enum.filter(heard, &(&1[:text] == line.text))
      assert first == again
      assert Enum.uniq_by(heard, & &1.id) == [text(:north, host, "Moi") |> Map.put(:id, 1), first]
    end
  end

  describe "report" do
    test "quotes what the server saw, never what the client sends; a guest may report", ctx do
      assert send_talk(ctx, :adult2, %{"item" => "coin_ha"}) == :ok
      assert send_talk(ctx, :teen, %{"item" => "word_sorry"}) == :ok

      forged = %{
        "user_id" => ctx.people.adult2.id,
        "reason" => "rude",
        "text" => "I will find you",
        "body" => "I will find you",
        "lines" => ["I will find you"]
      }

      assert call(ctx, :guest, "report", forged) == :ok

      assert [report] = Feedback.list("reports")

      assert {report.user_id, report.reported_user_id} ==
               {ctx.people.guest.id, ctx.people.adult2.id}

      assert {report.answer, report.body} == {"rude", "(coin_ha)"}
      assert report.details["room_code"] == ctx.room.code
      assert is_binary(report.details["game_instance_id"])
    end

    test "once per game; a spectator may report; nonsense is refused", ctx do
      report = %{"user_id" => ctx.people.adult.id, "reason" => "bothering"}
      assert call(ctx, :teen, "report", report) == :ok
      assert call(ctx, :teen, "report", report) == {:error, %{error: "already_reported"}}
      assert call(ctx, :watcher, "report", report) == :ok
      assert [%{body: nil}, %{body: nil}] = Feedback.list("reports")

      for bad <- [
            %{"user_id" => ctx.people.teen.id, "reason" => "rude"},
            %{"user_id" => ctx.people.watcher.id, "reason" => "rude"},
            %{"user_id" => Ecto.UUID.generate(), "reason" => "rude"},
            %{"user_id" => "bot_1", "reason" => "rude"},
            %{"user_id" => ctx.people.adult.id, "reason" => "cheating"},
            %{"reason" => "rude"}
          ] do
        assert call(ctx, :teen, "report", bad) == {:error, %{error: "invalid_report"}}
      end

      assert length(Feedback.list("reports")) == 2
    end

    test "a failed mail is logged and the report saved", ctx do
      mailer_env = Application.get_env(:pidro_server, PidroServer.Mailer)
      Application.put_env(:pidro_server, PidroServer.Mailer, adapter: ErrorMailer)
      on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Mailer, mailer_env) end)

      log =
        capture_log(fn ->
          report = %{"user_id" => ctx.people.guest.id, "reason" => "other"}
          assert call(ctx, :adult, "report", report) == :ok
          Process.sleep(100)
        end)

      assert log =~ "Report email delivery failed"
      assert [%{answer: "other"}] = Feedback.list("reports")
    end

    test "the room keeps the last 20 lines", ctx do
      for n <- 1..25,
          do: RoomManager.note_talk(ctx.room.code, %{user_id: "u", seat: :north, item: "#{n}"})

      {:ok, room} = RoomManager.get_room(ctx.room.code)
      assert Enum.map(room.talk, & &1.item) == Enum.map(25..6//-1, &"#{&1}")
      assert Enum.map(room.talk, & &1.id) == Enum.to_list(25..6//-1)
    end
  end

  describe "moment" do
    test "start reaches the four seats, not the spectator, and bidding brings none", ctx do
      {:ok, _} = GameAdapter.apply_action(ctx.room.code, :north, :select_dealer)

      assert received(ctx, "moment") ==
               for(
                 name <- [:adult, :adult2, :teen, :guest],
                 into: %{},
                 do: {name, [%{id: "start"}]}
               )

      bid_out(ctx.room.code)
      assert received(ctx, "moment") == %{}
    end

    test "partner_trick reaches the partner of the winner; game_end everyone seated", ctx do
      {:ok, _} = GameAdapter.apply_action(ctx.room.code, :north, :select_dealer)
      _ = received(ctx, "moment")

      sent = broadcast_events(ctx.room.code, [{:trick_won, :east, 5}, {:trick_won, :north, 0}])
      assert received(ctx, "moment") == %{guest: [%{id: "partner_trick"}]}

      sent = broadcast_events(ctx.room.code, [{:trick_won, :south, 1}], sent)
      assert received(ctx, "moment") == %{adult: [%{id: "partner_trick"}]}

      broadcast_events(ctx.room.code, [{:game_won, :north_south, 62}], sent)

      assert received(ctx, "moment") ==
               for(
                 name <- [:adult, :adult2, :teen, :guest],
                 into: %{},
                 do: {name, [%{id: "game_end"}]}
               )
    end

    test "a seated player who joins again is not told what happened before", ctx do
      {:ok, _} = GameAdapter.apply_action(ctx.room.code, :north, :select_dealer)
      _ = received(ctx, "moment")

      ctx =
        put_in(ctx.clients[:adult_again], client(:adult_again, ctx.people.adult, ctx.room.code))

      assert received(ctx, "moment") == %{}

      broadcast_events(ctx.room.code, [{:trick_won, :south, 1}])

      assert received(ctx, "moment") ==
               %{adult: [%{id: "partner_trick"}], adult_again: [%{id: "partner_trick"}]}
    end
  end

  test "a bot partner gets nothing; a human partner of a bot does" do
    [north, east] = [adult(), adult()]
    {:ok, room} = RoomManager.create_room(north.id, %{name: "Two and two"})
    {:ok, _, _} = RoomManager.join_room(room.code, east.id)
    for pos <- [:south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)
    PidroServer.RoomFixtures.ready_room(room.code)

    ctx = %{
      clients: %{north: client(:north, north, room.code), east: client(:east, east, room.code)}
    }

    {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    assert received(ctx, "moment") == %{north: [%{id: "start"}], east: [%{id: "start"}]}

    sent = broadcast_events(room.code, [{:trick_won, :north, 5}])
    assert received(ctx, "moment") == %{}

    broadcast_events(room.code, [{:trick_won, :west, 5}], sent)
    assert received(ctx, "moment") == %{east: [%{id: "partner_trick"}]}
  end

  describe "bots" do
    # PID-408 reverses PID-328's rule: a person at a bot table may send words
    # and coins, so the bots can be answered. Typed text still needs a human.
    test "a person at a bot table may send words and coins, never typed text" do
      player = adult()
      {:ok, room} = RoomManager.create_room(player.id, %{solo: true})
      ctx = %{clients: %{solo: client(:solo, player, room.code)}}

      assert send_talk(ctx, :solo, %{"item" => "word_hello"}) == {:error, %{error: "no_table"}}

      for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)

      assert send_talk(ctx, :solo, %{"item" => "coin_heart"}) == :ok
      assert %{solo: [%{item: "coin_heart"} | _]} = received(ctx)
      assert say(ctx, :solo, "hello bots") == {:error, %{error: "no_table"}}
      assert send_talk(ctx, :solo, %{"item" => "word_rude"}) == {:error, %{error: "invalid_item"}}
    end

    test "a word gets one bot's reply at most, a typed line none" do
      [north, south] = [adult(), adult()]
      {:ok, room} = RoomManager.create_room(north.id, %{name: "Two and two"})
      {:ok, _, _} = RoomManager.join_room(room.code, south.id, :south)
      for pos <- [:east, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)

      ctx = %{
        clients: %{
          north: client(:north, north, room.code),
          south: client(:south, south, room.code)
        }
      }

      assert say(ctx, :north, "hello all") == :ok
      assert bot_lines(ctx, 3_500) == []

      # Both bots qualify for hello; seeded so that one of them does reply.
      seed_room_manager(3)
      assert send_talk(ctx, :north, %{"item" => "word_hello"}) == :ok

      assert [%{seat: seat, user_id: "bot:" <> _, item: "line_" <> _ = item}] =
               bot_lines(ctx, 3_500)

      assert seat in [:east, :west] and item =~ "_reply_hello_"

      # A bot's own line is not a word to answer.
      {:ok, %{talk: [%{user_id: "bot:" <> _} | _]}} = RoomManager.get_room(room.code)
    end

    test "sorry is answered by the bot partner, and only by it" do
      player = adult()
      {:ok, room} = RoomManager.create_room(player.id, %{solo: true})
      for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)
      ctx = %{clients: %{solo: client(:solo, player, room.code)}}

      seed_room_manager(1)
      assert send_talk(ctx, :solo, %{"item" => "word_sorry"}) == :ok
      assert [%{seat: :south, item: "line_" <> item}] = bot_lines(ctx, 3_500)
      assert item =~ "_reply_sorry_"
    end

    test "a remark due in the auction, or for a word over six seconds old, is dropped" do
      player = adult()
      {:ok, room} = RoomManager.create_room(player.id, %{solo: true})
      for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)
      ctx = %{clients: %{solo: client(:solo, player, room.code)}}
      {:ok, %{seats: %{east: %{bot_persona: east}}}} = RoomManager.get_room(room.code)
      now = System.monotonic_time(:millisecond)

      # Control: the table is waiting, the remark lands.
      fire(room.code, east, "line_dry_hello_1", nil)
      fire(room.code, east, "line_dry_reply_hello_1", now - 2_000)
      fire(room.code, east, "line_dry_reply_hello_2", now - 7_000)

      assert Enum.map(bot_lines(ctx, 300), & &1.item) ==
               ["line_dry_hello_1", "line_dry_reply_hello_1"]

      PidroServer.RoomFixtures.ready_room(room.code)
      wait_for_phase(room.code, :bidding)
      _ = bot_lines(ctx, 3_500)
      {:ok, %{phase: :bidding}} = GameAdapter.get_state(room.code)

      fire(room.code, east, "line_dry_hello_2", nil)
      assert bot_lines(ctx, 300) == []
    end
  end

  defp fire(code, persona, item, heard_at),
    do: send(RoomManager, {:bot_talk, code, :east, persona, item, heard_at})

  # The room manager's own random state, so its bots' choices repeat.
  defp seed_room_manager(seed),
    do:
      :sys.replace_state(RoomManager, fn state -> :rand.seed(:exsss, {seed, 408, 1}) && state end)

  # Every bot line the clients received within `ms`, once each.
  defp bot_lines(_ctx, ms) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn ->
      receive do
        {:got, _name, "talk", %{user_id: "bot:" <> _} = line} -> line
        {:got, _name, "talk", _line} -> :skip
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.reject(&(&1 == :skip))
    |> Enum.uniq()
  end

  # A client process owns its socket: pushes and replies go to it, and it
  # forwards them to the test tagged with its name.
  defp client(name, user, code) do
    pid = start_client(name, user, code)
    assert_receive {:joined, ^name, reply}, 2_000
    Process.put({:reply, name}, reply)
    pid
  end

  defp start_client(name, user, code) do
    test = self()

    spawn_link(fn ->
      {:ok, socket} =
        connect(UserSocket, %{"token" => create_token(user)}, test_process: test)

      {:ok, reply, channel} = join(socket, GameChannel, "game:#{code}")
      send(test, {:joined, name, reply})
      relay(test, name, channel)
    end)
  end

  # Waits until `pid` has a call queued whose request `match?` accepts.
  defp await_call(pid, request?, tries \\ 100) do
    {:messages, messages} = Process.info(pid, :messages)

    cond do
      Enum.any?(messages, fn message ->
        match?({:"$gen_call", _from, _request}, message) and request?.(elem(message, 2))
      end) ->
        :ok

      tries == 0 ->
        flunk("no such call queued")

      true ->
        Process.sleep(10) && await_call(pid, request?, tries - 1)
    end
  end

  defp relay(test, name, channel) do
    receive do
      {:push, event, payload} ->
        ref = push(channel, event, payload)
        send(test, {:pushed, name, ref})

      %Phoenix.Socket.Message{event: event, payload: payload} ->
        send(test, {:got, name, event, payload})

      %Phoenix.Socket.Reply{ref: ref, status: status, payload: payload} ->
        send(test, {:reply, name, ref, status, payload})

      _other ->
        :ok
    end

    relay(test, name, channel)
  end

  defp send_talk(ctx, name, payload), do: call(ctx, name, "talk", payload)
  defp say(ctx, name, text), do: call(ctx, name, "say", %{"text" => text})
  defp text(seat, user, text), do: %{seat: seat, user_id: user.id, text: text}

  defp call(ctx, name, event, payload) do
    send(ctx.clients[name], {:push, event, payload})
    assert_receive {:pushed, ^name, ref}

    case assert_receive({:reply, ^name, ^ref, _status, _reply}, 2_000) do
      {_, _, _, :ok, empty} when empty == %{} -> :ok
      {_, _, _, status, reply} -> {status, reply}
    end
  end

  # Every `event` push each client received, without talk ids, waiting briefly for stragglers.
  defp received(ctx, event \\ "talk")

  defp received(ctx, "talk") do
    ctx
    |> received_raw()
    |> Map.new(fn {name, lines} -> {name, Enum.map(lines, &Map.delete(&1, :id))} end)
  end

  defp received(ctx, event), do: received_raw(ctx, event)

  defp received_raw(ctx, event \\ "talk", acc \\ %{}) do
    receive do
      {:got, name, ^event, payload} when is_map_key(ctx.clients, name) ->
        received_raw(ctx, event, Map.update(acc, name, [payload], &(&1 ++ [payload])))
    after
      150 -> acc
    end
  end

  # The talk a client's join reply carried, without ids.
  defp replay(name), do: Enum.map(Process.get({:reply, name}).talk, &Map.delete(&1, :id))

  # The live game, or the last snapshot sent, with `events` appended, as the
  # game would broadcast it. Returns the snapshot so a test can send the next.
  defp broadcast_events(code, events, snapshot \\ nil) do
    snapshot = snapshot || elem(GameAdapter.get_snapshot(code), 1)
    state = %{snapshot.state | events: snapshot.state.events ++ events}
    revision = snapshot.state_revision + 1

    snapshot =
      Map.merge(snapshot, %{state: state, state_revision: revision, transition_delay_ms: 0})

    Phoenix.PubSub.broadcast(PidroServer.PubSub, "game:#{code}", {:state_update, code, snapshot})
    snapshot
  end

  defp wait_for_phase(code, phase, tries \\ 100) do
    {:ok, state} = GameAdapter.get_state(code)

    cond do
      state.phase == phase -> state
      tries == 0 -> flunk("game stayed in #{state.phase}")
      true -> Process.sleep(50) && wait_for_phase(code, phase, tries - 1)
    end
  end

  defp wait_for_seat(code, position, status?, tries \\ 100) do
    {:ok, room} = RoomManager.get_room(code)

    cond do
      status?.(room.seats[position].status) -> room
      tries == 0 -> flunk("#{position} stayed #{room.seats[position].status}")
      true -> Process.sleep(20) && wait_for_seat(code, position, status?, tries - 1)
    end
  end

  # Everyone passes or makes the lowest bid until bidding is over.
  defp bid_out(code) do
    state = wait_for_phase(code, :bidding)
    seat = state.current_turn
    actions = Pidro.Game.Engine.legal_actions(state, seat)
    action = if :pass in actions, do: :pass, else: Enum.min(actions)
    {:ok, next} = GameAdapter.apply_action(code, seat, action)
    if next.phase == :bidding, do: bid_out(code)
  end

  defp talk(seat, user, item), do: %{seat: seat, user_id: user.id, item: item}

  defp adult, do: AccountsFixtures.user_fixture() |> age("18_plus")

  defp age(user, band), do: user |> Ecto.Changeset.change(age_band: band) |> Repo.update!()
end
