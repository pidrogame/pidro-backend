defmodule PidroServer.TranslateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PidroServer.Translate

  @english {"Bigger cards", "Your cards are bigger.\nOpen Settings → Sound."}

  test "asks Claude for casual Finland-Swedish JSON, with the English post" do
    test = self()

    Req.Test.stub(Translate, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, Jason.decode!(body)})
      Req.Test.json(conn, answer(~s({"title":"Större kort","body":"Rad ett\\nRad två"})))
    end)

    {title, body} = @english

    assert Translate.to_swedish(title, body) ==
             {:ok, %{title: "Större kort", body: "Rad ett\nRad två"}}

    assert_received {:request, conn, request}
    assert conn.method == "POST"
    assert conn.host == "api.anthropic.com" and conn.request_path == "/v1/messages"
    assert Plug.Conn.get_req_header(conn, "x-api-key") == ["anthropic-test-key"]
    assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

    assert %{"model" => "claude-sonnet-5-5", "max_tokens" => 2000, "system" => system} = request
    assert system =~ "Finland-Swedish card players"
    assert system =~ "casual, friendly Swedish"
    assert system =~ "every line break"
    assert system =~ ~s(Keep the word "Pidro")

    assert system =~
             "Inställningar (Settings), Ljud (Sound), Berätta för oss (Tell us), Nyheter (News), Vänner (Friends)"

    assert system =~ "no emoji"

    assert [%{"role" => "user", "content" => content}] = request["messages"]
    assert Jason.decode!(content) == %{"title" => title, "body" => body}
  end

  test "out of tokens while still thinking is an error" do
    Req.Test.stub(Translate, fn conn ->
      Req.Test.json(conn, %{
        "stop_reason" => "max_tokens",
        "content" => [%{"type" => "thinking", "thinking" => "The player base is Finland-Swedish"}]
      })
    end)

    log = capture_log(fn -> assert Translate.to_swedish("Hi", "Row") == {:error, :max_tokens} end)
    assert log =~ "ran out of tokens"
  end

  test "anything but the asked-for JSON is an error, never a guess" do
    Req.Test.stub(
      Translate,
      &Req.Test.json(&1, %{"stop_reason" => "end_turn", "content" => [thinking()]})
    )

    capture_log(fn -> assert Translate.to_swedish("Hi", "Row") == {:error, :bad_answer} end)

    for text <- [
          ~s(Here you go: {"title":"Hej","body":"Rad"}),
          ~s(```json\n{"title":"Hej","body":"Rad"}\n```),
          ~s({"title":"Hej"}),
          ~s({"title":"Hej","body":7})
        ] do
      Req.Test.stub(Translate, &Req.Test.json(&1, answer(text)))

      capture_log(fn -> assert Translate.to_swedish("Hi", "Row") == {:error, :bad_answer} end)
    end
  end

  test "an API error or a dropped connection is an error" do
    Req.Test.stub(Translate, fn conn ->
      conn |> Plug.Conn.put_status(529) |> Req.Test.json(%{"type" => "error"})
    end)

    log =
      capture_log(fn -> assert {:error, {:status, 529}} = Translate.to_swedish("Hi", "Row") end)

    assert log =~ "HTTP 529"
    refute log =~ "anthropic-test-key"

    Req.Test.stub(Translate, &Req.Test.transport_error(&1, :timeout))
    capture_log(fn -> assert {:error, _} = Translate.to_swedish("Hi", "Row") end)
  end

  # claude-sonnet-5-5 thinks first: a thinking block, then the text block.
  defp answer(text),
    do: %{
      "stop_reason" => "end_turn",
      "content" => [thinking(), %{"type" => "text", "text" => text}]
    }

  defp thinking,
    do: %{
      "type" => "thinking",
      "thinking" => ~s(Draft: {"title":"Fel","body":"Fel"}),
      "signature" => "sig"
    }
end
