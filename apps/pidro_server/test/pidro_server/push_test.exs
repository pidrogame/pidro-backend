defmodule PidroServer.PushTest do
  use PidroServer.DataCase, async: true

  import ExUnit.CaptureLog
  import PidroServer.AccountsFixtures

  alias PidroServer.Accounts.Auth
  alias PidroServer.Push
  alias PidroServer.Push.{Ticket, Token}

  @token "ExponentPushToken[aaaaaaaaaaaaaaaaaaaaaa]"

  defp attrs(token \\ @token, extra \\ %{}) do
    Map.merge(
      %{
        "token" => token,
        "platform" => "ios",
        "install_id" => "install-1",
        "app_version" => "3.3.0"
      },
      extra
    )
  end

  defp ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes, :minute)

  # Answers each message by its `to`, so the order Push sends them in does not matter.
  defp stub_send(answers) do
    test = self()

    Req.Test.stub(Push.Expo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      messages = Jason.decode!(body)
      send(test, {:sent, conn, messages})
      Req.Test.json(conn, %{"data" => Enum.map(messages, &Map.fetch!(answers, &1["to"]))})
    end)
  end

  describe "register/2" do
    test "upserts by token, and a token moves to whoever signs in on that phone last" do
      a = user_fixture()
      b = user_fixture()

      assert {:ok, first} = Push.register(a, attrs())
      assert {:ok, again} = Push.register(a, attrs(@token, %{"app_version" => "3.3.1"}))
      assert again.id == first.id and again.app_version == "3.3.1"
      assert Repo.aggregate(Token, :count) == 1

      Repo.update_all(Token, set: [disabled_at: DateTime.utc_now(), disabled_reason: "x"])

      assert {:ok, moved} = Push.register(b, attrs(@token, %{"platform" => "android"}))
      assert moved.id == first.id
      assert moved.user_id == b.id and moved.platform == "android"
      assert moved.disabled_at == nil and moved.disabled_reason == nil
      assert Push.tokens_for(a.id) == []
      assert [%Token{token: @token}] = Push.tokens_for(b.id)
    end

    test "takes Expo tokens only, from ios or android" do
      user = user_fixture()

      for token <- ["ExpoPushToken[abc-123_x]", "ExponentPushToken[xyz]"] do
        assert {:ok, %Token{token: ^token}} = Push.register(user, attrs(token))
      end

      for token <- [
            "abc",
            "ExponentPushToken[]",
            "ExponentPushToken[abc",
            "ExponentPushToken[a b]",
            " ExponentPushToken[abc]",
            "fcm:ExponentPushToken[abc]",
            nil
          ] do
        assert {:error, changeset} = Push.register(user, attrs(token))
        assert errors_on(changeset)[:token], "accepted #{inspect(token)}"
      end

      for platform <- ["web", nil] do
        assert {:error, changeset} =
                 Push.register(user, attrs("ExpoPushToken[p]", %{"platform" => platform}))

        assert errors_on(changeset)[:platform]
      end
    end
  end

  test "unregister/2 deletes only the caller's own token, and is idempotent" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Push.register(a, attrs())

    assert Push.unregister(b, @token) == :ok
    assert [_] = Push.tokens_for(a.id)

    assert Push.unregister(a, @token) == :ok
    assert Push.unregister(a, @token) == :ok
    assert Push.tokens_for(a.id) == []
  end

  describe "send/2" do
    test "sends to every enabled phone, keeps ok tickets and disables unregistered devices" do
      user = user_fixture()
      other = user_fixture()
      [ok, gone, big, off] = for n <- 1..4, do: "ExponentPushToken[#{n}]"
      for token <- [ok, gone, big, off], do: {:ok, _} = Push.register(user, attrs(token))
      {:ok, _} = Push.register(other, attrs("ExponentPushToken[other]"))
      Repo.update_all(from(t in Token, where: t.token == ^off), set: [disabled_at: ago(1)])

      stub_send(%{
        ok => %{"status" => "ok", "id" => "ticket-ok"},
        gone => %{
          "status" => "error",
          "message" => ~s("#{gone}" is not a registered push notification recipient),
          "details" => %{"error" => "DeviceNotRegistered"}
        },
        big => %{
          "status" => "error",
          "message" => "Message too big",
          "details" => %{"error" => "MessageTooBig"}
        }
      })

      log =
        capture_log(fn ->
          assert Push.send(user.id, %{title: "Hi", body: "Your table", data: %{url: "/t/1"}}) ==
                   {:ok, %{sent: 1, failed: 2}}
        end)

      assert_received {:sent, conn, messages}
      assert conn.host == "exp.host" and conn.request_path == "/--/api/v2/push/send"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expo-test-token"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

      assert Enum.sort_by(messages, & &1["to"]) ==
               for(
                 to <- [ok, gone, big],
                 do: %{
                   "to" => to,
                   "title" => "Hi",
                   "body" => "Your table",
                   "data" => %{"url" => "/t/1"},
                   "sound" => "default",
                   "channelId" => "default"
                 }
               )

      assert [%Ticket{ticket_id: "ticket-ok", title: "Hi", receipt_status: nil} = ticket] =
               Repo.all(Ticket)

      assert Repo.get!(Token, ticket.token_id).token == ok
      assert ticket.sent_at && is_nil(ticket.checked_at)

      assert Repo.get_by!(Token, token: gone).disabled_reason == "DeviceNotRegistered"
      assert Repo.get_by!(Token, token: gone).disabled_at
      assert Repo.get_by!(Token, token: big).disabled_at == nil
      assert Enum.map(Push.tokens_for(user.id), & &1.token) |> Enum.sort() == [ok, big]

      assert log =~ "DeviceNotRegistered"
      assert log =~ "MessageTooBig"
      refute log =~ "PushToken["
    end

    test "posts at most 100 messages per request" do
      user = user_fixture()
      tokens = for n <- 1..101, do: "ExpoPushToken[#{n}]"
      for token <- tokens, do: {:ok, _} = Push.register(user, attrs(token))
      stub_send(Map.new(tokens, &{&1, %{"status" => "ok", "id" => "id-" <> &1}}))

      assert Push.send(user.id, %{title: "T", body: "B"}) == {:ok, %{sent: 101, failed: 0}}
      assert_received {:sent, _, first}
      assert_received {:sent, _, second}
      assert Enum.sort([length(first), length(second)]) == [1, 100]
      assert Repo.aggregate(Ticket, :count) == 101
    end

    test "a player without phones sends nothing" do
      # No stub: a request would raise.
      assert Push.send(user_fixture().id, %{title: "T", body: "B"}) ==
               {:ok, %{sent: 0, failed: 0}}
    end

    test "a network or HTTP failure is an error, never a raise, and changes nothing" do
      user = user_fixture()
      {:ok, _} = Push.register(user, attrs())

      Req.Test.stub(Push.Expo, &Req.Test.transport_error(&1, :econnrefused))

      log =
        capture_log(fn ->
          assert {:error, %Req.TransportError{reason: :econnrefused}} =
                   Push.send(user.id, %{title: "T", body: "B"})
        end)

      assert log =~ "econnrefused"

      Req.Test.stub(Push.Expo, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"errors" => [%{"code" => "X"}]})
      end)

      capture_log(fn ->
        assert {:error, {:status, 500, ["X"]}} = Push.send(user.id, %{title: "T", body: "B"})
      end)

      assert Repo.aggregate(Ticket, :count) == 0
      assert [%Token{disabled_at: nil}] = Push.tokens_for(user.id)
    end
  end

  describe "check_receipts/0" do
    setup do
      user = user_fixture()
      {:ok, token} = Push.register(user, attrs())
      {:ok, gone} = Push.register(user, attrs("ExponentPushToken[gone]"))
      {:ok, back} = Push.register(user, attrs("ExponentPushToken[back]"))
      Repo.update_all(from(t in Token, where: t.id != ^back.id), set: [last_used_at: ago(60)])

      ticket = fn id, token, sent_at, extra ->
        Repo.insert!(
          struct(
            %Ticket{token_id: token.id, ticket_id: id, title: "T", sent_at: sent_at},
            extra
          )
        )
      end

      %{user: user, token: token, gone: gone, back: back, ticket: ticket}
    end

    test "stores the receipts of tickets older than 15 minutes and disables unregistered devices",
         %{user: user, token: token, gone: gone, back: back, ticket: ticket} do
      ticket.("ok", token, ago(20), %{})
      # The app registered this phone again after the push went out.
      ticket.("dnr-back", back, ago(20), %{})
      ticket.("err", token, ago(20), %{})
      ticket.("dnr", gone, ago(16), %{})
      ticket.("not-yet", token, ago(30), %{})
      ticket.("lost", token, ago(25 * 60), %{})
      ticket.("fresh", token, ago(5), %{})
      ticket.("done", token, ago(60), %{checked_at: ago(40), receipt_status: "ok"})

      test = self()

      Req.Test.stub(Push.Expo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:asked, conn.request_path, Jason.decode!(body)["ids"]})

        Req.Test.json(conn, %{
          "data" => %{
            "ok" => %{"status" => "ok"},
            "err" => %{
              "status" => "error",
              "message" => "rate",
              "details" => %{"error" => "MessageRateExceeded"}
            },
            "dnr" => %{
              "status" => "error",
              "message" => "gone",
              "details" => %{"error" => "DeviceNotRegistered"}
            },
            "dnr-back" => %{
              "status" => "error",
              "message" => "gone",
              "details" => %{"error" => "DeviceNotRegistered"}
            }
          }
        })
      end)

      capture_log(fn -> assert Push.check_receipts() == {:ok, %{checked: 5}} end)

      assert_received {:asked, "/--/api/v2/push/getReceipts", ids}
      assert Enum.sort(ids) == ~w(dnr dnr-back err lost not-yet ok)

      status = fn id -> Repo.get_by!(Ticket, ticket_id: id) end
      assert %{receipt_status: "ok", receipt_error: nil, checked_at: %DateTime{}} = status.("ok")

      assert %{receipt_status: "error", receipt_error: "MessageRateExceeded"} = status.("err")
      assert %{receipt_status: "error", receipt_error: "DeviceNotRegistered"} = status.("dnr")
      # Expo keeps receipts for a day; past that there is nothing left to ask for.
      assert %{receipt_status: "expired", checked_at: %DateTime{}} = status.("lost")
      assert %{receipt_status: nil, checked_at: nil} = status.("not-yet")
      assert %{receipt_status: nil, checked_at: nil} = status.("fresh")

      assert Repo.get!(Token, gone.id).disabled_reason == "DeviceNotRegistered"

      assert Enum.sort(Enum.map(Push.tokens_for(user.id), & &1.id)) ==
               Enum.sort([token.id, back.id])
    end

    test "nothing due asks Expo for nothing; a failure leaves tickets for the next run",
         %{token: token, ticket: ticket} do
      assert Push.check_receipts() == {:ok, %{checked: 0}}

      ticket.("ok", token, ago(20), %{})
      Req.Test.stub(Push.Expo, &Req.Test.transport_error(&1, :timeout))

      capture_log(fn -> assert {:error, %Req.TransportError{}} = Push.check_receipts() end)
      assert %{checked_at: nil} = Repo.get_by!(Ticket, ticket_id: "ok")
    end
  end

  test "deleting the account deletes its tokens and their tickets" do
    user = user_fixture()
    other = user_fixture()
    {:ok, token} = Push.register(user, attrs())
    {:ok, kept} = Push.register(other, attrs("ExpoPushToken[kept]"))

    for t <- [token, kept],
        do: Repo.insert!(%Ticket{token_id: t.id, ticket_id: "t#{t.id}", sent_at: ago(1)})

    assert {:ok, _} = Auth.delete_user(user)
    assert [%Token{id: id}] = Repo.all(Token)
    assert id == kept.id
    assert [%Ticket{token_id: ^id}] = Repo.all(Ticket)
  end
end
