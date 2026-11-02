defmodule PidroServerWeb.Dev.HistoryLiveTest do
  use PidroServer.ArchiveCase, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Plug.Conn
  import PidroServerWeb.ConnCase
  import Ecto.Query

  alias PidroServer.{AccountsFixtures, GameArchive, GameReports, Repo, RoomFixtures}
  alias PidroServer.GameArchive.Archive
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Stats.GameStats

  @endpoint PidroServerWeb.Endpoint
  setup do
    admin_ids = Repo.all(from a in PidroServer.Admins.Admin, select: a.id)

    on_exit(fn ->
      Repo.delete_all(from a in PidroServer.Admins.Admin, where: a.id not in ^admin_ids)
    end)

    {:ok, conn: build_conn()}
  end

  setup :register_and_log_in_admin

  setup do
    RoomManager.reset_for_test()
    config = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(config,
        dealer_selection_delay_ms: 0,
        deal_transition_delay_ms: 0,
        turn_timer_bid_ms: 600_000,
        turn_timer_play_ms: 600_000
      )
    )

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      Application.put_env(:pidro_server, Lifecycle, config)
    end)

    :ok
  end

  test "real create, deal, bid, report, leave remains inspectable without a room", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{display_name: "Joachim"})
    {:ok, room} = RoomManager.create_room(user.id, %{solo: true})

    for position <- [:east, :south, :west],
        do: BotManager.start_bot(room.code, position, :basic, 5_000)

    RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    assert {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    wait(fn -> Pidro.Server.get_state(pid).phase == :bidding end)
    live_snapshot = Pidro.Server.get_snapshot(pid)

    assert {:ok, _} =
             GameAdapter.apply_action(room.code, live_snapshot.state.current_turn, {:bid, 8})

    instance = live_snapshot.game_instance_id

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{PidroServer.Accounts.Token.generate(user)}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/game-reports", Jason.encode!(report_body(room.code, instance)))
      |> json_response(201)

    report_id = response["data"]["id"]
    assert :ok = RoomManager.leave_room(user.id)
    assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    refute Process.alive?(pid)

    {:ok, view, html} =
      live(conn, "/admin/history?player=Joachim&room_code=#{room.code}&status=closed")

    assert html =~ instance
    assert html =~ "Abandoned / closed"
    assert has_element?(view, "a[href='/admin/history/#{instance}']")

    {:ok, view, html} = live(conn, "/admin/history/#{instance}")
    assert html =~ "Joachim"
    assert html =~ "bid_made"
    assert html =~ "Last saved revision"
    assert has_element?(view, "a[href='/admin/reports/#{report_id}']")

    refute has_element?(
             view,
             "[phx-click=execute_action], [phx-click=play_card], [phx-click=select_position]"
           )

    assert html =~ "UTC"

    render_patch(view, "/admin/history/#{instance}?revision=0")
    assert render(view) =~ "revision 0"
    render_patch(view, "/admin/history/#{instance}?revision=999999")
    assert render(view) =~ "No saved snapshot at this revision"

    {:ok, report_view, html} = live(conn, "/admin/reports/#{report_id}")
    assert html =~ "Client-reported timeline"
    assert html =~ "Unverified claims"
    assert html =~ "Abandoned / closed"
    assert has_element?(report_view, "a[href='/admin/users/#{user.id}']")
    assert has_element?(report_view, "a[href='/admin/history/#{instance}']")
  end

  test "archives keep reused rooms distinct, paginate equal timestamps, and honor time boundaries",
       %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    for n <- 1..26,
        do: checkpoint("instance-#{String.pad_leading(to_string(n), 2, "0")}", user.id)

    Repo.update_all(from(a in Archive, where: ^user.id in a.user_ids),
      set: [started_at: ~U[2026-10-22 12:00:00.000000Z]]
    )

    {:ok, view, html} =
      live(
        conn,
        "/admin/history?user_id=#{user.id}&from=2026-10-22T14:00:00%2B02:00&to=2026-10-22T12:00:01Z"
      )

    assert has_element?(view, "#history-results article:nth-child(25)")
    refute has_element?(view, "#history-results article:nth-child(26)")
    assert html =~ "instance-26"
    refute html =~ "instance-01"

    assert {:ok, _, older} =
             view |> element("a", "Older results") |> render_click() |> follow_redirect(conn)

    assert older =~ "instance-01"
    refute older =~ "instance-02"

    {:ok, _, html} = live(conn, "/admin/history?user_id=#{user.id}&to=2026-10-22T12:00:00Z")
    assert html =~ "No matching evidence"
    {:ok, _, html} = live(conn, "/admin/history?game_instance_id=instance-04")
    assert html =~ "instance-04"
    refute html =~ "instance-05"
  end

  test "invalid filters, malformed cursor and ambiguous player names do not widen search", %{
    conn: conn
  } do
    AccountsFixtures.user_fixture(%{display_name: "Same Name"})
    AccountsFixtures.user_fixture(%{display_name: "Same Name"})

    for query <- [
          "user_id=bad",
          "status=oops",
          "from=2026-10-22",
          "revision=-1",
          "user_id[]=bad",
          "from=2026-10-23T00:00:00Z&to=2026-10-22T00:00:00Z",
          "before_id=only-one",
          "player=Same%20Name"
        ] do
      {:ok, view, _} = live(conn, "/admin/history?" <> query)
      assert has_element?(view, "[role=alert]")
      refute has_element?(view, "#history-results")
    end

    for path <- ["/admin/reports", "/admin/history/summaries"] do
      {:ok, view, _} = live(conn, path <> "?before_id=not-uuid&before_at=2026-10-22T00:00:00Z")
      assert has_element?(view, "[role=alert]", "Invalid page cursor")
    end
  end

  test "outcome, partial coverage and absent or unsupported evidence are not replay claims", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    checkpoint("partial", user.id)
    checkpoint("interrupted", user.id)
    checkpoint("completed", user.id)

    Repo.update_all(from(a in Archive, where: a.game_instance_id == "partial"),
      set: [evidence_status: "partial", missing_revision_count: 3, status: "closed"]
    )

    Repo.update_all(from(a in Archive, where: a.game_instance_id == "interrupted"),
      set: [status: "interrupted", evidence_status: "uncertain"]
    )

    Repo.update_all(from(a in Archive, where: a.game_instance_id == "completed"),
      set: [status: "complete", format_version: 99]
    )

    for {id, label} <- [
          {"partial", "Partial archive"},
          {"interrupted", "not a known crash time"},
          {"completed", "Unsupported archive format"},
          {"missing", "No archive for this instance"}
        ] do
      {:ok, _, html} = live(conn, "/admin/history/#{id}")
      assert html =~ label
    end

    Repo.query!("ALTER TABLE game_archives RENAME TO temporarily_unavailable_archives")

    try do
      {:ok, view, html} = live(conn, "/admin/history")
      assert has_element?(view, "[role=alert]", "Evidence storage is unavailable")
      refute html =~ "No matching evidence"
    after
      Repo.query!("ALTER TABLE temporarily_unavailable_archives RENAME TO game_archives")
    end
  end

  test "report filters use exact instance, user, build and report ID; client text is escaped", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    checkpoint("reported-one", user.id)
    checkpoint("reported-two", user.id)
    {:ok, first} = GameReports.create(user.id, report_body("SAME", "reported-one"))
    {:ok, second} = GameReports.create(user.id, report_body("SAME", "reported-two"))

    {:ok, _, html} =
      live(
        conn,
        "/admin/reports?user_id=#{user.id}&game_instance_id=reported-one&build=42&report_id=#{first.id}"
      )

    assert html =~ first.id
    refute html =~ second.id
    # Defense-in-depth against legacy/untrusted persisted text, beyond ingestion validation.
    first
    |> Ecto.Changeset.change(
      events: [
        %{
          "type" => "<script>alert(1)</script>",
          "action" => "none",
          "code" => "failed",
          "offset_ms" => 0
        }
      ]
    )
    |> Repo.update!()

    {:ok, _, html} = live(conn, "/admin/reports/#{first.id}")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert(1)</script>"
  end

  test "saved seat states, cold players and scoring are faithfully projected", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    seats = %{
      north: %{user_id: user.id, occupant_type: :human, status: :reconnecting},
      east: %{occupant_type: :human, status: :grace},
      south: %{occupant_type: :human, status: :connected, substitute: true},
      west: %{occupant_type: :bot, status: :bot_substitute, substitute: false}
    }

    state = Pidro.Core.GameState.new(seed: 7) |> Map.put(:phase, :scoring)
    state = put_in(state.players.north.eliminated?, true)

    snapshot = %{
      game_instance_id: "saved-seats",
      state_revision: 0,
      state: state,
      presentation: %{},
      server_time_ms: System.system_time(:millisecond)
    }

    GameArchive.checkpoint!("SAME", seats, snapshot, %{
      kind: :start,
      engine_events: [],
      events_replaced: false
    })

    {:ok, view, _} = live(conn, "/admin/history/saved-seats")
    assert has_element?(view, ".watch-phase", "scoring")
    assert has_element?(view, "#watch-seat-north", "Reconnecting")
    assert has_element?(view, "#watch-seat-north", "Cold")
    assert has_element?(view, "#watch-seat-east", "Reconnecting")
    assert has_element?(view, "#watch-seat-south", "Connected")
    refute has_element?(view, "#watch-seat-south", "Bot covering")
    assert has_element?(view, "#watch-seat-west", "Bot covering")

    Repo.get!(Archive, "saved-seats")
    |> Ecto.Changeset.change(participants: %{}, participation_truncated: true)
    |> Repo.update!()

    html = render_patch(view, "/admin/history/saved-seats")
    assert html =~ "No initial seat evidence was captured"
    assert html =~ "Player search may omit later participants"
    assert has_element?(view, "#watch-seat-north", "unknown")
    refute has_element?(view, "#watch-seat-north", "Connected")
    refute has_element?(view, "#watch-seat-north", "Open")
  end

  test "developer host IDs cannot crash archived account resolution", %{conn: conn} do
    checkpoint("developer-host", "warehouse worker")
    {:ok, view, html} = live(conn, "/admin/history/developer-host")
    assert html =~ "Unknown player"
    refute has_element?(view, "a[href^='/admin/users/warehouse']")
  end

  test "legacy summaries never link a reused room without an instance", %{conn: conn} do
    summary =
      Repo.insert!(%GameStats{
        room_code: "SAME",
        completed_at: ~U[2025-10-01 12:00:00Z],
        final_scores: %{"north_south" => 62, "east_west" => 27}
      })

    {:ok, view, html} = live(conn, "/admin/history/summaries/#{summary.id}")
    assert html =~ "Summary-only"
    assert html =~ "No instance ID was recorded"
    assert html =~ "62"
    refute has_element?(view, "a[href='/admin/games/SAME']")
    {:ok, _, html} = live(conn, "/admin/history/summaries?room_code=SAME")
    assert html =~ summary.id
  end

  test "anonymous, player, temporary and revoked admin sessions cannot read private evidence", %{
    conn: conn,
    admin: admin
  } do
    for path <- [
          "/admin/history",
          "/admin/history/secret",
          "/admin/reports",
          "/admin/reports/#{Ecto.UUID.generate()}"
        ] do
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), path)
    end

    player_conn =
      build_conn()
      |> put_req_header(
        "authorization",
        "Bearer #{PidroServer.Accounts.Token.generate(AccountsFixtures.user_fixture())}"
      )

    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(player_conn, "/admin/history")
    {:ok, view, _} = live(conn, "/admin/history")
    Repo.delete_all(from t in PidroServer.Admins.AdminToken, where: t.admin_id == ^admin.id)
    render_patch(view, "/admin/history?room_code=SAME")
    assert_redirect(view, "/admin/login")
    temporary = PidroServer.AdminsFixtures.admin_fixture(%{force_password_change: true})

    assert {:error, {:redirect, %{to: "/admin/admins"}}} =
             live(log_in_admin(build_conn(), temporary), "/admin/history")
  end

  test "archive rows batch current names and distinguish initial bots, unknown and empty seats",
       %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{display_name: "Original name"})
    for n <- 1..25, do: checkpoint("roster-#{n}", user.id)
    user |> Ecto.Changeset.change(display_name: "Current name") |> Repo.update!()

    participants = %{
      "north" => %{"user_id" => user.id, "occupant_type" => "human", "status" => "connected"},
      "south" => %{"occupant_type" => "bot", "bot_persona" => "antti"},
      "east" => %{"user_id" => Ecto.UUID.generate(), "occupant_type" => "human"},
      "west" => %{"occupant_type" => "vacant"}
    }

    Repo.update_all(from(a in Archive, where: ^user.id in a.user_ids),
      set: [participants: participants]
    )

    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:pidro_server, :repo, :query],
      fn _, _, meta, owner ->
        if meta.source == "users", do: send(owner, :user_query)
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, view, html} = live(conn, "/admin/history?room_code=SAME")
    assert has_element?(view, "#history-results article:nth-child(25)", "Current name")
    assert html =~ "Initial roster · current names"
    assert html =~ "Antti"
    assert html =~ "Unknown player"
    assert html =~ "Open seat"
    refute html =~ "Connected"
    refute html =~ "Original name"
    # One batch in each of the disconnected and connected mounts, not per row/seat.
    assert_received :user_query
    assert_received :user_query
    refute_received :user_query
  end

  test "playback uses only saved checkpoints, shows gaps and never mutates evidence", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()

    for {revision, score} <- [{0, 0}, {2, -8}, {5, 13}, {6, 26}],
        do: checkpoint("playback", user.id, revision, score)

    before = GameArchive.events("playback")
    {:ok, view, _} = live(conn, "/admin/history/playback?revision=0")
    assert has_element?(view, "#checkpoint-range[min='0'][max='3'][value='0']")
    assert has_element?(view, "button[phx-value-direction=previous][disabled]")
    assert has_element?(view, "#archive-gap-warning", "Missing checkpoints: 3")
    refute has_element?(view, "#timeline-details[open]")
    view |> element("button[phx-value-direction=next]") |> render_click()
    assert has_element?(view, "#checkpoint-label", "revision 2")
    assert has_element?(view, ".watch-team-ns strong", "-8")
    assert has_element?(view, "#playback-notice", "Missing revisions skipped")
    view |> form("#checkpoint-seek", checkpoint: "2") |> render_change()
    assert has_element?(view, "#checkpoint-label", "revision 5")
    assert has_element?(view, "#checkpoint-range[value='2'][aria-valuetext='Saved revision 5']")
    # Queued input events select absolute checkpoint positions, regardless of prior responses.
    render_hook(view, "seek", %{"checkpoint" => "2"})
    assert has_element?(view, "#checkpoint-label", "revision 5")
    render_hook(view, "seek", %{"checkpoint" => "3"})
    assert has_element?(view, "#checkpoint-label", "revision 6")
    view |> form("#checkpoint-seek", checkpoint: "1") |> render_change()
    assert has_element?(view, "#checkpoint-label", "revision 2")
    view |> element("button[phx-value-direction=next]") |> render_click()
    assert has_element?(view, ".watch-team-ns strong", "13")
    view |> element("button[phx-value-direction=last]") |> render_click()
    assert has_element?(view, "button[phx-value-direction=next][disabled]")
    assert has_element?(view, ".watch-team-ns strong", "26")
    view |> element("button[phx-value-direction=previous]") |> render_click()
    assert has_element?(view, "#checkpoint-label", "revision 5")
    render_patch(view, "/admin/history/playback?revision=4")
    assert render(view) =~ "No saved snapshot at this revision"
    refute has_element?(view, "#watch-table")
    view |> element("button[phx-value-direction=next]") |> render_click()
    assert has_element?(view, "#checkpoint-label", "revision 5")
    assert GameArchive.events("playback") == before
    refute has_element?(view, "[phx-click=play_card], [phx-click=execute_action]")
  end

  test "real timers honor speed changes, pause, seek while playing, end, restart and URL navigation",
       %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    for revision <- [0, 2, 5, 6], do: checkpoint("timed", user.id, revision)
    {:ok, view, _} = live(conn, "/admin/history/timed?revision=0")
    view |> form("#playback-speed", speed: "0.5") |> render_change()
    view |> element("#play-toggle") |> render_click()
    assert has_element?(view, "#playback-state", "Playing")
    Process.sleep(300)
    assert has_element?(view, "#checkpoint-label", "revision 0")
    view |> form("#playback-speed", speed: "4") |> render_change()
    wait(fn -> has_element?(view, "#checkpoint-label", "revision 2") end)
    view |> element("#play-toggle") |> render_click()
    Process.sleep(350)
    assert has_element?(view, "#checkpoint-label", "revision 2")
    assert has_element?(view, "#playback-state", "Paused")
    view |> form("#playback-speed", speed: "0.5") |> render_change()
    view |> element("#play-toggle") |> render_click()
    view |> form("#checkpoint-seek", checkpoint: "2") |> render_change()
    assert has_element?(view, "#checkpoint-label", "revision 5")
    assert has_element?(view, "#playback-state", "Playing")
    view |> form("#playback-speed", speed: "4") |> render_change()
    wait(fn -> has_element?(view, "#playback-state", "End of saved checkpoints") end)
    assert has_element?(view, "#checkpoint-label", "revision 6")
    view |> element("#play-toggle") |> render_click()
    assert has_element?(view, "#checkpoint-label", "revision 0")
    assert has_element?(view, "#playback-state", "Playing")
    render_patch(view, "/admin/history/timed?revision=5")
    Process.sleep(350)
    assert has_element?(view, "#checkpoint-label", "revision 5")
    assert has_element?(view, "#playback-state", "Paused")
  end

  test "empty, single and unsupported histories disable playback; malformed events are harmless",
       %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    for id <- ["empty-playback", "single", "future"], do: checkpoint(id, user.id)

    Repo.delete_all(
      from e in PidroServer.GameArchive.Event, where: e.game_instance_id == "empty-playback"
    )

    Repo.update_all(from(a in Archive, where: a.game_instance_id == "future"),
      set: [format_version: 99]
    )

    for id <- ["empty-playback", "single", "future"] do
      {:ok, view, _} = live(conn, "/admin/history/#{id}")
      assert has_element?(view, "#play-toggle[disabled]")
      assert has_element?(view, "#checkpoint-range[disabled]")

      for {event, params} <- [
            {"toggle_playback", %{}},
            {"seek", %{"checkpoint" => []}},
            {"seek", %{"checkpoint" => "-2"}},
            {"seek", %{"checkpoint" => "2oops"}},
            {"speed", %{"speed" => "0"}},
            {"step", %{"direction" => "sideways"}}
          ],
          do: render_hook(view, event, params)

      refute has_element?(view, "#playback-state", "Playing")
    end
  end

  for invalidation <- [:revoked, :expired, :temporary_password] do
    test "#{invalidation} sessions stop on the next playback tick without another user event", %{
      conn: conn,
      admin: admin
    } do
      user = AccountsFixtures.user_fixture()
      for revision <- [0, 1, 2], do: checkpoint("revoke-playback", user.id, revision)
      {:ok, view, _} = live(conn, "/admin/history/revoke-playback?revision=0")
      view |> form("#playback-speed", speed: "4") |> render_change()
      view |> element("#play-toggle") |> render_click()
      tokens = from t in PidroServer.Admins.AdminToken, where: t.admin_id == ^admin.id

      case unquote(invalidation) do
        :revoked ->
          Repo.delete_all(tokens)

        :expired ->
          Repo.update_all(tokens, set: [last_used_at: ~U[2000-01-01 00:00:00.000000Z]])

        :temporary_password ->
          admin |> Ecto.Changeset.change(force_password_change: true) |> Repo.update!()
      end

      assert_redirect(
        view,
        if(unquote(invalidation) == :temporary_password,
          do: "/admin/admins",
          else: "/admin/login"
        ),
        2_000
      )
    end
  end

  test "new checkpoints arriving during lookup cannot relabel the displayed snapshot", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    checkpoint("concurrent-save", user.id)
    handler = {__MODULE__, make_ref()}
    Process.put(:save_during_read, true)

    :telemetry.attach(
      handler,
      [:pidro_server, :repo, :query],
      fn _, _, meta, _ ->
        if meta.source == "game_archives" and Process.delete(:save_during_read) do
          checkpoint("concurrent-save", user.id, 1, 14)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    # The disconnected mount reads revision 0 metadata before the revision 1 save.
    html = conn |> get("/admin/history/concurrent-save") |> html_response(200)
    assert html =~ "Saved table · revision 0"
    assert html =~ ~s(max="0")
    assert html =~ ~s(&quot;state_revision&quot;: 0)
    refute html =~ ~s(&quot;state_revision&quot;: 1)
    assert GameArchive.get("concurrent-save").last_revision == 1
  end

  test "slower cadences advance, and navigation stops the old playback", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    for revision <- [0, 1, 2, 3], do: checkpoint("cadence", user.id, revision)

    for speed <- ["0.5", "1", "2"] do
      {:ok, view, _} = live(conn, "/admin/history/cadence?revision=0")
      view |> form("#playback-speed", speed: speed) |> render_change()
      view |> element("#play-toggle") |> render_click()
      Process.sleep(if speed == "0.5", do: 1_100, else: 200)
      assert has_element?(view, "#checkpoint-label", "revision 0")
      wait(fn -> has_element?(view, "#checkpoint-label", "revision 1") end, 150)
      ref = Process.monitor(view.pid)

      assert {:ok, _, _} =
               view |> element("a", "Archives") |> render_click() |> follow_redirect(conn)

      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    end
  end

  defp checkpoint(id, user_id, revision \\ 0, score \\ 0) do
    state = %{
      Pidro.Core.GameState.new(seed: 7)
      | cumulative_scores: %{north_south: score, east_west: 3}
    }

    snapshot = %{
      game_instance_id: id,
      state_revision: revision,
      state: state,
      presentation: %{},
      server_time_ms: System.system_time(:millisecond)
    }

    GameArchive.checkpoint!(
      "SAME",
      %{north: %{user_id: user_id, occupant_type: :human}},
      snapshot,
      %{kind: :start, engine_events: [], events_replaced: false}
    )
  end

  defp report_body(room, instance),
    do: %{
      "room_code" => room,
      "game_instance_id" => instance,
      "app_version" => "1.2.3",
      "build" => "42",
      "platform" => "ios",
      "events" => [
        %{
          "type" => "timeout",
          "code" => "unavailable",
          "action" => "bid",
          "offset_ms" => 37,
          "state_revision" => 2
        }
      ]
    }

  defp wait(fun, attempts \\ 100)
  defp wait(fun, 0), do: assert(fun.())

  defp wait(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      wait(fun, attempts - 1)
    end
  end
end
