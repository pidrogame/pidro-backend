defmodule PidroServerWeb.API.GameReportControllerTest do
  use PidroServerWeb.ConnCase, async: false
  import PidroServer.AccountsFixtures
  alias PidroServer.{GameReports, Repo}
  alias PidroServer.Accounts.Token
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServer.Stats.GameStats

  setup do
    if is_nil(Process.whereis(RoomManager)), do: start_supervised!(RoomManager)
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    user = user_fixture()
    instance = Ecto.UUID.generate()

    Repo.insert!(%GameStats{
      room_code: "ABCDEF",
      game_instance_id: instance,
      player_ids: [user.id],
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    body = %{
      "room_code" => "ABCDEF",
      "game_instance_id" => instance,
      "app_version" => "1.2.3",
      "build" => "42",
      "platform" => "ios",
      "events" => [
        %{
          "type" => "tap",
          "code" => "ok",
          "action" => "bid",
          "offset_ms" => 0,
          "action_id" => "attempt-1",
          "state_revision" => 17
        }
      ]
    }

    %{user: user, body: body}
  end

  # The pre-parser throttle counts per clock minute (Hammer's fixed window), so a
  # burst that straddles a minute boundary meets a fresh count, as it would in
  # production. That run proves nothing: run it once more from empty counters,
  # inside the new minute.
  defp in_one_minute(burst) do
    minute = div(System.system_time(:millisecond), 60_000)

    try do
      burst.()
    rescue
      error ->
        if div(System.system_time(:millisecond), 60_000) == minute,
          do: reraise(error, __STACKTRACE__)

        PidroServerWeb.RateLimitCase.reset()
        burst.()
    end
  end

  defp submit(user, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/game-reports", Jason.encode!(body))
  end

  test "persists only authoritative ownership and server metadata", %{user: user, body: body} do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {response, log} =
      ExUnit.CaptureLog.with_log([formatter: {PidroServer.DiagnosticsFormatter, %{}}], fn ->
        submit(user, body) |> json_response(201)
      end)

    report = GameReports.admin_get(response["data"]["id"])
    assert report.user_id == user.id
    assert report.events == body["events"]
    assert report.inserted_at
    assert report.id != body["game_instance_id"]
    assert Enum.any?(GameReports.admin_list(), &(&1.id == report.id))
    assert log =~ report.id
    assert log =~ "report_created"
    refute log =~ "attempt-1"
    refute log =~ "Bearer"
  end

  test "requires exact bearer auth", %{body: body} do
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/game-reports", Jason.encode!(body))
           |> json_response(401)

    assert build_conn()
           |> put_req_header("authorization", "bearer invalid")
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/game-reports", Jason.encode!(body))
           |> json_response(401)
  end

  test "rejects spoofing, cards, credentials and unknown nested keys", %{user: user, body: body} do
    for key <- ~w(user_id token cards password) do
      assert submit(user, Map.put(body, key, user.id)) |> json_response(422)
      event = body["events"] |> hd() |> Map.put(key, "secret")
      assert submit(user, Map.put(body, "events", [event])) |> json_response(422)
    end

    assert GameReports.admin_list() == []
  end

  test "requires exact game membership, not room knowledge", %{user: user, body: body} do
    assert submit(user_fixture(), body) |> json_response(403)

    assert submit(user, Map.put(body, "game_instance_id", Ecto.UUID.generate()))
           |> json_response(403)

    assert submit(user, Map.put(body, "room_code", "REUSED")) |> json_response(403)
    assert GameReports.admin_list() == []
  end

  test "durable per-user quota is five per rolling hour", %{user: user, body: body} do
    for _ <- 1..5, do: assert(submit(user, body) |> json_response(201))
    conn = submit(user, body)
    assert json_response(conn, 429)
    assert get_resp_header(conn, "retry-after") == ["3600"]
    assert length(GameReports.admin_list()) == 5
  end

  test "invalid-report spam is bounded before membership queries", %{user: user} do
    in_one_minute(fn ->
      for _ <- 1..10, do: assert(submit(user, %{}) |> json_response(422))
      assert submit(user, %{}) |> json_response(429)
    end)

    assert GameReports.admin_list() == []
  end

  test "malformed, non-object, oversized and wrong-media attempts also consume the budget" do
    for {raw, content_type, status} <- [
          {"{", "application/json", 400},
          {"[]", "application/json", 400},
          {String.duplicate("x", 32_769), "application/json", 413},
          {"hello", "text/plain", 415}
        ] do
      token = Token.generate(user_fixture())

      send_raw = fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", content_type)
        |> post("/api/v1/game-reports", raw)
      end

      in_one_minute(fn ->
        for _ <- 1..10, do: assert(send_raw.() |> json_response(status))
        assert send_raw.() |> json_response(429)
      end)
    end

    assert GameReports.admin_list() == []
  end

  test "encoded route spellings cannot bypass pre-parser bounds or throttling" do
    for path <- ["/api/v1/%67ame-reports", "/%61pi/v1/game-reports"] do
      token = Token.generate(user_fixture())

      send_raw = fn raw ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post(path, raw)
      end

      in_one_minute(fn ->
        assert send_raw.(String.duplicate("x", 32_769)) |> json_response(413)
        for _ <- 1..9, do: assert(send_raw.("{}") |> json_response(422))
        assert send_raw.("{}") |> json_response(429)
      end)
    end
  end

  test "early report responses preserve allowed-origin CORS and never allow an untrusted origin" do
    original = Application.get_env(:pidro_server, :cors_origins)
    Application.put_env(:pidro_server, :cors_origins, ["https://play.example"])
    on_exit(fn -> Application.put_env(:pidro_server, :cors_origins, original) end)

    for origin <- ["https://play.example", "https://untrusted.example"] do
      token = Token.generate(user_fixture())

      send_raw = fn raw, type, bearer ->
        build_conn()
        |> put_req_header("origin", origin)
        |> put_req_header("authorization", "Bearer #{bearer}")
        |> put_req_header("content-type", type)
        |> post("/api/v1/game-reports", raw)
      end

      {responses, limited} =
        in_one_minute(fn ->
          responses = [
            {send_raw.("{}", "application/json", "invalid"), 401},
            {send_raw.("{", "application/json", token), 400},
            {send_raw.(String.duplicate("x", 32_769), "application/json", token), 413},
            {send_raw.("hello", "text/plain", token), 415}
          ]

          for _ <- 1..7,
              do: assert(send_raw.("{}", "application/json", token) |> json_response(422))

          limited = send_raw.("{}", "application/json", token)
          assert get_resp_header(limited, "retry-after") == ["60"]
          {responses, limited}
        end)

      for {conn, status} <- responses ++ [{limited, 429}] do
        assert json_response(conn, status)

        if origin == "https://play.example" do
          assert get_resp_header(conn, "access-control-allow-origin") == [origin]

          assert Enum.join(get_resp_header(conn, "access-control-expose-headers")) =~
                   "retry-after"
        else
          refute origin in get_resp_header(conn, "access-control-allow-origin")
          refute "*" in get_resp_header(conn, "access-control-allow-origin")
        end
      end
    end
  end

  test "admin search applies exact filters, UTC boundaries and timestamp/id keysets", %{
    user: user,
    body: body
  } do
    at = ~U[2026-10-20 12:00:00.000000Z]
    other = user_fixture()

    rows =
      for {suffix, seconds, owner, build} <- [
            {1, -1, user.id, "42"},
            {2, 0, user.id, "42"},
            {3, 0, user.id, "43"},
            {4, 1, other.id, "44"}
          ] do
        Repo.insert!(%PidroServer.GameReports.Report{
          id: "00000000-0000-0000-0000-00000000000#{suffix}",
          user_id: owner,
          room_code: body["room_code"],
          game_instance_id: body["game_instance_id"],
          app_version: "1.2.3",
          build: build,
          platform: "ios",
          events: body["events"],
          inserted_at: DateTime.add(at, seconds)
        })
      end

    [older, low, high, newer] = rows
    assert GameReports.admin_search(limit: 2) == [newer, high]
    assert GameReports.admin_search(before: {high.inserted_at, high.id}, limit: 2) == [low, older]
    assert GameReports.admin_search(from: at, to: DateTime.add(at, 1)) == [high, low]
    assert GameReports.admin_search(to: at) == [older]
    assert GameReports.admin_search(user_id: other.id) == [newer]
    assert GameReports.admin_search(build: "42") == [low, older]

    assert GameReports.admin_search(
             report_id: low.id,
             user_id: user.id,
             game_instance_id: body["game_instance_id"],
             room_code: body["room_code"],
             build: "42"
           ) == [low]

    for filter <- [
          [room_code: "OTHER"],
          [game_instance_id: "other"],
          [report_id: low.id, user_id: other.id]
        ] do
      assert GameReports.admin_search(filter) == []
    end

    for filter <- [
          [limit: 0],
          [limit: 101],
          [user_id: "invalid"],
          [from: "yesterday"],
          [unknown: true]
        ] do
      assert_raise ArgumentError, fn -> GameReports.admin_search(filter) end
    end
  end

  test "rejects out-of-range revisions, tokens and oversized strings", %{user: user, body: body} do
    event = hd(body["events"])

    for invalid <- [
          Map.put(event, "state_revision", -1),
          Map.put(event, "state_revision", 9_007_199_254_740_992),
          Map.put(event, "action_id", "eyJheader.eyJpayload.signature"),
          Map.put(event, "action_id", String.duplicate("x", 65)),
          Map.put(event, "code", "private free text")
        ] do
      assert submit(user, Map.put(body, "events", [invalid])) |> json_response(422)
    end

    assert submit(user, Map.put(body, "app_version", String.duplicate("1", 33)))
           |> json_response(422)

    assert GameReports.admin_list() == []
  end

  test "bounds raw body before JSON parsing and bounds event count", %{user: user, body: body} do
    assert submit(user, Map.put(body, "events", List.duplicate(hd(body["events"]), 101)))
           |> json_response(422)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/game-reports", String.duplicate("x", 32_769))

    assert json_response(conn, 413)
    assert GameReports.admin_list() == []
  end

  test "ops cleanup deletes only expired rows and honors batch bound", %{user: user, body: body} do
    for _ <- 1..3, do: assert(submit(user, body) |> json_response(201))
    [fresh | old] = GameReports.admin_list()

    for report <- old do
      report
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -31 * 86_400))
      |> Repo.update!()
    end

    assert {1, nil} = GameReports.cleanup(1)
    assert {1, nil} = GameReports.cleanup(1)
    assert {0, nil} = GameReports.cleanup()
    assert GameReports.admin_get(fresh.id)
  end

  test "supervised scheduled retention runs repeatedly against the real database", %{
    user: user,
    body: body
  } do
    id = submit(user, body) |> json_response(201) |> get_in(["data", "id"])

    pid =
      start_supervised!(
        {PidroServer.GameReports.Cleanup, [name: nil, enabled: true, interval_ms: 20]}
      )

    for _ <- 1..2 do
      GameReports.admin_get(id)
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -31 * 86_400))
      |> Repo.update!()

      assert wait_until_deleted(id, 100)
      assert Process.alive?(pid)

      if is_nil(GameReports.admin_get(id)) do
        Repo.insert!(%PidroServer.GameReports.Report{
          id: id,
          user_id: user.id,
          room_code: body["room_code"],
          game_instance_id: body["game_instance_id"],
          app_version: "1.2.3",
          build: "42",
          platform: "ios",
          events: body["events"]
        })
      end
    end

    assert GameReports.admin_get(id)
  end

  defp wait_until_deleted(_id, 0), do: false

  defp wait_until_deleted(id, attempts) do
    if GameReports.admin_get(id) do
      Process.sleep(10)
      wait_until_deleted(id, attempts - 1)
    else
      true
    end
  end

  test "current seated players only, wrong instances and missing games fail closed", %{
    user: user,
    body: body
  } do
    # This case proves the no-archive fallback. Integrated archives correctly
    # preserve participation after stop_game and have separate closure coverage.
    archive_lookup = Application.get_env(:pidro_server, :game_report_archive_lookup)
    Application.delete_env(:pidro_server, :game_report_archive_lookup)

    on_exit(fn ->
      Application.put_env(:pidro_server, :game_report_archive_lookup, archive_lookup)
    end)

    {:ok, room} = RoomManager.create_room(user.id, %{})

    for _ <- 1..3 do
      {:ok, _, _} = RoomManager.join_room(room.code, user_fixture().id)
    end

    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, snapshot} = GameAdapter.get_snapshot(room.code)
    body = %{body | "room_code" => room.code, "game_instance_id" => snapshot.game_instance_id}
    assert submit(user, body) |> json_response(201)
    outsider = user_fixture()
    {:ok, _} = RoomManager.join_spectator_room(room.code, outsider.id)
    assert submit(outsider, body) |> json_response(403)

    assert submit(user, Map.put(body, "game_instance_id", Ecto.UUID.generate()))
           |> json_response(403)

    :ok = PidroServer.Games.GameSupervisor.stop_game(room.code)
    assert submit(user, body) |> json_response(403)
  end

  test "database errors fail closed without inserting", %{user: user, body: body} do
    {:ok, room} = RoomManager.create_room(user.id, %{})
    for _ <- 1..3, do: RoomManager.join_room(room.code, user_fixture().id)
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, before} = GameAdapter.get_snapshot(room.code)
    # Transaction-local relation rename forces the real quota query to fail,
    # while the membership query and bearer authentication still work.
    Repo.transaction(fn ->
      Repo.query!("ALTER TABLE game_reports RENAME TO unavailable_game_reports")
      assert submit(user, body) |> json_response(503)

      assert {:ok, _} =
               RoomManager.apply_player_action(room.code, user.id, :north, :select_dealer)

      assert {:ok, after_action} = GameAdapter.get_snapshot(room.code)
      assert after_action.state_revision > before.state_revision
      Repo.rollback(:expected)
    end)

    assert GameReports.admin_list() == []
  end
end
