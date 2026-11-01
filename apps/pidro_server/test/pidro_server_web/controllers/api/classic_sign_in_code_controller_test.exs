defmodule PidroServerWeb.API.ClassicSignInCodeControllerTest do
  use PidroServerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PidroServer.Accounts.{
    ClassicClaims,
    ClassicClaimTicket,
    ClassicClient,
    ClassicSignInCodes,
    Token
  }

  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo
  alias PidroServerWeb.Plugs.RateLimit

  @params %{login: "Bengt", install_id: "install-A"}
  @profile %{
    "id" => 177_001,
    "username" => "Bengt",
    "email" => "bengt@example.com",
    "level" => 14,
    "games" => %{"total_game" => 88},
    "account" => %{"visible" => true, "deleted" => false}
  }

  defmodule BlockingMailer do
    use Swoosh.Adapter

    def deliver(email, _config) do
      [test | _] = Process.get(:"$callers")
      send(test, {:mail_waiting, self(), email})

      receive do
        :fail -> {:error, {:rejected, email}}
        :raise -> raise inspect(email)
        :exit -> exit({:rejected, email})
      end
    end
  end

  setup do
    stub_profile(@profile)
    :ok
  end

  test "emails a six-digit proof, returns the shared preview and redeems Classic's identity", %{
    conn: conn
  } do
    response = conn |> post(~p"/api/v1/classic/sign-in-code", @params) |> json_response(200)
    assert response == %{"data" => %{"email_hint" => "be•••••@example.com"}}

    OpenApiSpex.TestAssertions.assert_schema(
      response,
      "Classic sign-in code response",
      PidroServerWeb.ApiSpec.spec()
    )

    assert_receive {:email, email}
    assert email.to == [{"", "bengt@example.com"}]
    assert email.from == {"Pidro", System.get_env("MAIL_FROM_ADDRESS") || "noreply@pidro.online"}
    assert email.subject == "Your Pidro sign-in code"
    code = mail_code(email)
    assert email.text_body =~ "It works for 15 minutes"

    assert email.text_body =~
             ~s(on the screen that says "Check your email". It is not a new password)

    assert email.text_body =~ ~s(på sidan där det står "Kolla din e-post". Det är inte ett nytt)

    assert email.html_body =~ "Pidro, the card game from Ostrobothnia"
    assert email.html_body =~ code

    row = Repo.one!(ClassicSignInCodes)
    assert row.code_hash == :crypto.hash(:sha256, "177001" <> code)
    assert DateTime.diff(row.expires_at, row.inserted_at) in 899..900

    verified = verify(conn, code) |> json_response(200)

    OpenApiSpex.TestAssertions.assert_schema(
      verified,
      "Classic ownership verification response",
      PidroServerWeb.ApiSpec.spec()
    )

    assert verified["data"]["already_claimed"] == nil

    assert verified["data"]["classic"] == %{
             "name" => "Bengt",
             "games_played" => 88,
             "level" => 14,
             "member_since" => nil,
             "name_allowed" => true,
             "new_account" => %{"username" => "Bengt", "email" => "bengt@example.com"}
           }

    assert %{method: :password, matched_on: :email} = Repo.one!(ClassicClaimTicket)

    assert {:ok, user} =
             ClassicClaims.redeem(verified["data"]["ticket"], nil, %{
               install_id: "install-A",
               account: %{password: "new-password-177"}
             })

    assert user.username == "Bengt"
    assert user.email == "bengt@example.com"
    assert user.classic_matched_on == :email
    refute user.guest
    assert_invalid(verify(conn, code))
  end

  test "short local parts expose only their first character", %{conn: conn} do
    stub_profile(Map.put(@profile, "email", "al@x.fi"))

    assert %{"data" => %{"email_hint" => "a•••••@x.fi"}} =
             conn |> post(~p"/api/v1/classic/sign-in-code", @params) |> json_response(200)

    assert_receive {:email, _}
  end

  test "template building does not reject an address accepted by Classic", %{conn: conn} do
    stub_profile(Map.put(@profile, "email", "player@localhost"))

    assert %{"data" => %{"email_hint" => "pl•••••@localhost"}} =
             conn |> post(~p"/api/v1/classic/sign-in-code", @params) |> json_response(200)

    assert_receive {:email, email}
    assert email.to == [{"", "player@localhost"}]
    assert mail_code(email)
  end

  test "reports missing accounts and missing email honestly", %{conn: conn} do
    stub_status(404)

    assert_error(
      post(conn, ~p"/api/v1/classic/sign-in-code", @params),
      404,
      "CLASSIC_ACCOUNT_NOT_FOUND"
    )

    assert_invalid(verify(conn, "123456"))

    for email <- [nil, "", "   "] do
      stub_profile(Map.put(@profile, "email", email))

      assert_error(
        post(conn, ~p"/api/v1/classic/sign-in-code", @params),
        422,
        "CLASSIC_EMAIL_MISSING"
      )
    end

    assert Repo.aggregate(ClassicSignInCodes, :count) == 0
    refute_received {:email, _}
  end

  test "Classic 400 and 503 remain provider failures on both routes", %{conn: conn} do
    for status <- [400, 503] do
      stub_status(status)

      assert_error(
        post(conn, ~p"/api/v1/classic/sign-in-code", @params),
        503,
        "PROVIDER_UNAVAILABLE"
      )

      assert_error(verify(conn, "123456"), 503, "PROVIDER_UNAVAILABLE")
    end
  end

  test "five wrong guesses consume the proof; the sixth correct guess fails", %{conn: conn} do
    code = request_code(conn)
    wrong = if code == "000000", do: "000001", else: "000000"
    for _ <- 1..5, do: assert_invalid(verify(conn, wrong))
    assert_invalid(verify(conn, code))
    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "four wrong guesses still allow a correct fifth attempt", %{conn: conn} do
    code = request_code(conn)
    for _ <- 1..4, do: assert_invalid(verify(conn, "not-six-digits"))
    assert %{"data" => %{"ticket" => _}} = verify(conn, code) |> json_response(200)
  end

  test "expired proofs fail and a new request replaces them", %{conn: conn} do
    old = request_code(conn)
    row = Repo.one!(ClassicSignInCodes)
    row |> Ecto.Changeset.change(expires_at: DateTime.utc_now()) |> Repo.update!()
    assert_invalid(verify(conn, old))
    fresh = request_code(conn)
    assert Repo.aggregate(ClassicSignInCodes, :count) == 1
    refute Repo.get(ClassicSignInCodes, row.id)
    assert %{"data" => _} = verify(conn, fresh) |> json_response(200)
  end

  test "a resend invalidates the older open code", %{conn: conn} do
    old = request_code(conn)
    fresh = request_code(conn, Map.put(@params, :install_id, "install-B"))
    # Different bindings make this deterministic even in a one-in-a-million code collision.
    assert_invalid(verify(conn, old))
    if old != fresh, do: assert_invalid(verify(conn, old, %{install_id: "install-B"}))
    assert %{"data" => _} = verify(conn, fresh, %{install_id: "install-B"}) |> json_response(200)
  end

  test "install and Bearer bindings cannot be exchanged", %{conn: conn} do
    code = request_code(conn)
    guest = AccountsFixtures.guest_fixture()
    signed_in = put_req_header(conn, "authorization", "Bearer #{Token.generate(guest)}")
    assert_invalid(verify(conn, code, %{install_id: "install-B"}))
    assert_invalid(verify(signed_in, code))
    assert %{"data" => _} = verify(conn, code) |> json_response(200)

    code = request_code(signed_in, %{login: "Bengt"})
    other = AccountsFixtures.guest_fixture()
    other_conn = put_req_header(conn, "authorization", "Bearer #{Token.generate(other)}")
    assert_invalid(verify(conn, code))
    assert_invalid(verify(other_conn, code))
    data = verify(signed_in, code, %{install_id: "ignored"}) |> json_response(200)

    assert {:ok, user} =
             ClassicClaims.redeem(data["data"]["ticket"], guest, %{
               account: %{password: "new-password-177"}
             })

    assert user.id == guest.id
    assert user.username == "Bengt"
    assert user.email == "bengt@example.com"
  end

  test "missing binding, malformed input and invalid Bearer never create proofs", %{conn: conn} do
    for install <- [nil, "", String.duplicate("x", 65)] do
      assert_error(
        post(conn, ~p"/api/v1/classic/sign-in-code", %{login: "Bengt", install_id: install}),
        422,
        "CLAIM_BINDING_REQUIRED"
      )

      assert_invalid(verify(conn, "123456", %{install_id: install}))
    end

    for login <- [nil, " ", [], 123] do
      assert post(conn, ~p"/api/v1/classic/sign-in-code", Map.put(@params, :login, login))
             |> json_response(422)

      assert_invalid(verify(conn, "123456", %{login: login}))
    end

    bad_bearer = put_req_header(conn, "authorization", "not-a-bearer")
    assert post(bad_bearer, ~p"/api/v1/classic/sign-in-code", @params) |> json_response(401)
    assert Repo.aggregate(ClassicSignInCodes, :count) == 0
  end

  test "deleted and hidden accounts cannot request or verify a code", %{conn: conn} do
    code = request_code(conn)

    for account <- [
          %{"deleted" => true, "visible" => true},
          %{"deleted" => false, "visible" => false}
        ] do
      stub_profile(Map.put(@profile, "account", account))

      assert_error(
        post(conn, ~p"/api/v1/classic/sign-in-code", @params),
        404,
        "CLASSIC_ACCOUNT_NOT_FOUND"
      )

      assert_invalid(verify(conn, code))
    end

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "ticket failure rolls back consumption so the code can be retried", %{conn: conn} do
    code = request_code(conn)
    stub_profile(Map.put(@profile, "level", nil))
    assert_error(verify(conn, code), 503, "PROVIDER_UNAVAILABLE")
    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
    stub_profile(@profile)
    assert %{"data" => _} = verify(conn, code) |> json_response(200)
  end

  test "deleting a bound user also deletes their code", %{conn: conn} do
    guest = AccountsFixtures.guest_fixture()
    request_code(put_req_header(conn, "authorization", "Bearer #{Token.generate(guest)}"))
    Repo.delete!(guest)
    assert Repo.aggregate(ClassicSignInCodes, :count) == 0
  end

  test "identifier limit is shared by trimmed, case-folded login variants", %{conn: conn} do
    limit(:classic_sign_in_code_identifier, 3)
    login = "rate-#{System.unique_integer([:positive])}"

    for value <- [login, String.upcase(login), " #{login} "] do
      request_code(conn, Map.put(@params, :login, value))
    end

    assert_error(
      post(conn, ~p"/api/v1/classic/sign-in-code", Map.put(@params, :login, login)),
      429,
      "RATE_LIMITED"
    )
  end

  test "request and verify share the IP limit", %{conn: conn} do
    limit(:classic_sign_in_code, 1)
    conn = %{conn | remote_ip: {192, 0, 2, 177}}
    code = request_code(conn)
    assert_error(verify(conn, code), 429, "RATE_LIMITED")
  end

  for {failure, classification} <- [
        {:fail, ":unknown"},
        {:raise, "{:error, RuntimeError}"},
        {:exit, "{:exit, :unknown}"}
      ] do
    test "mail #{failure} cannot alter the sent 200 or leak the code", %{conn: conn} do
      original = Application.fetch_env!(:pidro_server, PidroServer.Mailer)
      Application.put_env(:pidro_server, PidroServer.Mailer, adapter: BlockingMailer)
      on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Mailer, original) end)

      log =
        capture_log(fn ->
          response = post(conn, ~p"/api/v1/classic/sign-in-code", @params)
          assert response.state == :sent
          assert %{"data" => %{"email_hint" => _}} = json_response(response, 200)
          assert_receive {:mail_waiting, sender, email}
          ref = Process.monitor(sender)
          code = mail_code(email)
          send(self(), {:code_for_log_check, code})
          send(sender, unquote(failure))
          assert_receive {:DOWN, ^ref, :process, ^sender, :normal}
        end)

      assert_receive {:code_for_log_check, code}
      assert log =~ "Classic sign-in code email delivery failed"
      assert log =~ unquote(classification)
      refute log =~ code
      refute log =~ "bengt@example.com"
    end
  end

  test "submitted codes are absent from parameter logs", %{conn: conn} do
    code = request_code(conn)
    log = capture_log([level: :debug], fn -> assert verify(conn, code) |> json_response(200) end)
    refute log =~ code
  end

  defp stub_profile(profile) do
    Req.Test.stub(ClassicClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "GET"
      assert conn.request_path == "/internal/claims/lookup"
      assert Map.keys(conn.query_params) == ["login"]
      Req.Test.json(conn, %{"classic" => profile})
    end)
  end

  defp stub_status(status) do
    Req.Test.stub(ClassicClient, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "unavailable"})
    end)
  end

  defp request_code(conn, params \\ @params) do
    assert post(conn, ~p"/api/v1/classic/sign-in-code", params) |> json_response(200)
    assert_receive {:email, email}
    mail_code(email)
  end

  defp mail_code(email) do
    [code] = Regex.run(~r/^\d{6}$/m, email.text_body)
    code
  end

  defp verify(conn, code, extra \\ %{}) do
    post(
      conn,
      ~p"/api/v1/classic/sign-in-code/verify",
      @params |> Map.put(:code, code) |> Map.merge(extra)
    )
  end

  defp assert_invalid(conn) do
    body = assert_error(conn, 401, "CLASSIC_CODE_INVALID")
    assert hd(body["errors"])["detail"] == "That code didn't work. Ask for a new one."
  end

  defp assert_error(conn, status, code) do
    body = json_response(conn, status)
    assert [%{"code" => ^code}] = body["errors"]
    assert body["error_code"] == String.downcase(code)
    body
  end

  defp limit(policy, count) do
    original = Application.fetch_env!(:pidro_server, RateLimit)
    updated = Keyword.update!(original, policy, &Map.put(&1, :limit, count))
    Application.put_env(:pidro_server, RateLimit, updated)
    on_exit(fn -> Application.put_env(:pidro_server, RateLimit, original) end)
  end
end
