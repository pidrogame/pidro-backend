defmodule PidroServerWeb.SentryTest do
  # Sentry's configuration, the Req stubs and the HTTP listener are global.
  use PidroServerWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias PidroServer.AccountsFixtures
  alias PidroServer.SentryTestClient

  @dsn "http://public@sentry.test/1"
  @email "crash.reporter@example.com"
  @username "crashreporter"

  setup do
    on_exit(fn ->
      Sentry.put_config(:dsn, nil)
      Sentry.put_config(:client, Sentry.FinchClient)
      Sentry.put_config(:dedup_events, true)
    end)

    Sentry.put_config(:client, SentryTestClient)
    Sentry.put_config(:dedup_events, false)
    SentryTestClient.listen()

    user = AccountsFixtures.user_fixture(%{email: @email, username: @username})
    %{user: user, token: PidroServer.Accounts.Token.generate(user)}
  end

  describe "with a DSN" do
    setup do
      Sentry.put_config(:dsn, @dsn)
    end

    test "a controller exception sends one event with the release and no personal data",
         %{token: token} do
      crash_classic_verify(token)

      event = only_event!([@email, token, "secret-cookie", "classic-password", "127.0.0.1"])
      assert event["release"] == Application.fetch_env!(:pidro_server, :server_build)
      assert event["environment"] == "test"
      assert [%{"type" => "RuntimeError", "value" => "Classic is down"}] = exceptions(event)
      assert "PidroServerWeb.API.ClassicClaimController.verify/2" in functions(event)
    end

    test "a crashed channel sends one event with the release and no personal data",
         %{user: user, token: token} do
      crash_lobby_channel(user)

      event = only_event!([@email, @username, token, user.id, "4821"])
      assert event["release"] == Application.fetch_env!(:pidro_server, :server_build)
      assert event["environment"] == "test"
      assert [%{"type" => "FunctionClauseError"}] = exceptions(event)
      assert "PidroServerWeb.LobbyChannel.handle_info/2" in functions(event)
    end
  end

  test "without a DSN nothing is sent", %{user: user, token: token} do
    Sentry.put_config(:dsn, nil)

    crash_classic_verify(token)
    crash_lobby_channel(user)

    refute_receive {:sentry_envelope, _}, 500
  end

  # A real request through Bandit, as in production.
  defp crash_classic_verify(token) do
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(PidroServer.Accounts.ClassicClient, fn _conn -> raise "Classic is down" end)

    server = start_supervised!({Bandit, plug: PidroServerWeb.Endpoint, ip: :loopback, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    capture_log(fn ->
      response =
        Req.post!("http://127.0.0.1:#{port}/api/v1/classic/verify?email=#{@email}",
          json: %{method: "password", login: @email, password: "classic-password"},
          headers: [authorization: "Bearer #{token}", cookie: "session=secret-cookie"],
          retry: false
        )

      assert response.status == 500
    end)
  end

  defp crash_lobby_channel(user) do
    {:ok, socket} = create_socket(user)
    {:ok, _reply, socket} = subscribe_and_join(socket, PidroServerWeb.LobbyChannel, "lobby")
    Process.flag(:trap_exit, true)
    ref = Process.monitor(socket.channel_pid)

    capture_log(fn ->
      send(socket.channel_pid, {:seat_password, %{email: @email, password: "4821"}})
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    end)
  end

  # The envelope is what would leave the server, so the personal data is
  # searched for in its raw bytes, not in a decoded struct.
  defp only_event!(personal_data) do
    assert_receive {:sentry_envelope, envelope}, 2_000
    refute_receive {:sentry_envelope, _}, 300

    for value <- personal_data, do: refute(envelope =~ value, "#{inspect(value)} was sent")

    [_header, _item_header, payload | _] = String.split(envelope, "\n")
    Jason.decode!(payload)
  end

  defp exceptions(event), do: Enum.map(event["exception"], &Map.take(&1, ["type", "value"]))

  defp functions(event),
    do: for(e <- event["exception"], f <- e["stacktrace"]["frames"], do: f["function"])
end
