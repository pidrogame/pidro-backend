defmodule PidroServerWeb.MetaDataDeletionControllerTest do
  use PidroServerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PidroServer.Accounts.{
    ClassicClaimTicket,
    FacebookDataDeletion,
    ProviderIdentity,
    User,
    UserIdentities,
    UserIdentity
  }

  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  @secret "facebook-test-secret"

  # Built the way Meta does: base64url JSON payload, HMAC-SHA256 of the encoded
  # payload with the app secret, joined as `<signature>.<payload>`.
  defp signed_request(user_id, secret \\ @secret) do
    payload =
      %{"algorithm" => "HMAC-SHA256", "issued_at" => 1_795_000_000, "user_id" => user_id}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)

    signature <> "." <> payload
  end

  defp facebook_user(subject) do
    user = AccountsFixtures.user_fixture()

    {:ok, _user} =
      UserIdentities.link(user, %{provider: :facebook, subject: subject, email: nil}, :sign_up)

    user
  end

  # A Facebook Classic claim that was never finished: no account, but the id.
  defp claim_ticket(subject) do
    Repo.insert!(%ClassicClaimTicket{
      token_hash: :crypto.strong_rand_bytes(32),
      classic_user_id: 40_001,
      method: :facebook,
      provider_id: subject,
      provider_email: "aino@example.com",
      install_id: "install-#{subject}",
      legacy_data: %{},
      expires_at: DateTime.add(DateTime.utc_now(), 600)
    })
  end

  # Classic's callback answers with `status` and tells the test what it got.
  defp stub_classic(status) do
    test = self()

    Req.Test.stub(FacebookDataDeletion, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:classic, conn.method, conn.request_path, URI.decode_query(body)})
      Plug.Conn.send_resp(conn, status, "{}")
    end)
  end

  defp deliver(conn, signed_request) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(~p"/meta/data-deletion", URI.encode_query(%{signed_request: signed_request}))
  end

  test "a valid request deletes the matching account and answers Meta's JSON", %{conn: conn} do
    stub_classic(200)
    user = facebook_user("10229876543210")
    bystander = facebook_user("10220000000001")
    request = signed_request("10229876543210")

    assert %{"url" => url, "confirmation_code" => code} =
             conn |> deliver(request) |> json_response(200)

    assert url == "http://localhost:4002/meta/data-deletion/#{code}"
    assert Repo.get(User, user.id) == nil
    assert Repo.get_by(UserIdentity, provider: :facebook, subject: "10229876543210") == nil
    assert Repo.get(User, bystander.id)
    assert %FacebookDataDeletion{outcome: :deleted} = Repo.get(FacebookDataDeletion, code)

    assert_receive {:classic, "POST", "/v2/meta/data_deletion", %{"signed_request" => ^request}}
  end

  test "an unknown Facebook id answers a confirmation and deletes nobody", %{conn: conn} do
    stub_classic(200)
    bystander = facebook_user("10220000000001")
    unfinished = claim_ticket("19999999999999")
    other_ticket = claim_ticket("10220000000001")
    users = Repo.aggregate(User, :count)

    assert %{"url" => _url, "confirmation_code" => code} =
             conn |> deliver(signed_request("19999999999999")) |> json_response(200)

    assert Repo.aggregate(User, :count) == users
    assert Repo.get(User, bystander.id)
    assert %FacebookDataDeletion{outcome: :no_account} = Repo.get(FacebookDataDeletion, code)
    assert Repo.get(ClassicClaimTicket, unfinished.id) == nil
    assert Repo.get(ClassicClaimTicket, other_ticket.id)
    assert_receive {:classic, "POST", _path, _body}
  end

  test "a bad signature answers 400 and deletes nothing", %{conn: conn} do
    stub_classic(200)
    user = facebook_user("10229876543210")
    [_signature, payload] = String.split(signed_request("10229876543210"), ".")

    for request <- [
          signed_request("10229876543210", "the-old-apps-secret"),
          Base.url_encode64("forged", padding: false) <> "." <> payload,
          payload,
          ""
        ] do
      assert conn |> deliver(request) |> json_response(400)
      # Classic still gets it: it checks the signature with its own secret.
      assert_receive {:classic, "POST", _path, %{"signed_request" => ^request}}
    end

    assert conn |> post(~p"/meta/data-deletion", %{}) |> json_response(400)
    assert Repo.get(User, user.id)
    assert Repo.aggregate(FacebookDataDeletion, :count) == 0
  end

  test "with no app secret configured, nothing verifies" do
    config = Application.fetch_env!(:pidro_server, ProviderIdentity)
    on_exit(fn -> Application.put_env(:pidro_server, ProviderIdentity, config) end)

    assert {:ok, "10229876543210"} =
             ProviderIdentity.facebook_signed_request(signed_request("10229876543210"))

    Application.put_env(
      :pidro_server,
      ProviderIdentity,
      Keyword.put(config, :facebook_app_secret, "")
    )

    assert {:error, :invalid_credentials} =
             ProviderIdentity.facebook_signed_request(signed_request("10229876543210", ""))
  end

  test "Classic failing or unreachable only logs, and never changes our answer", %{conn: conn} do
    for {stub, logged} <- [
          {&Plug.Conn.send_resp(&1, 500, ""), "Classic answered 500"},
          {&Req.Test.transport_error(&1, :econnrefused), "Could not forward"}
        ] do
      Req.Test.stub(FacebookDataDeletion, stub)

      log =
        capture_log(fn ->
          {:ok, pid} = FacebookDataDeletion.forward_to_classic(signed_request("10229876543210"))
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert log =~ logged
    end

    test = self()
    user = facebook_user("10229876543210")

    Req.Test.stub(FacebookDataDeletion, fn conn ->
      send(test, :classic_tried)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert %{"confirmation_code" => code} =
             conn |> deliver(signed_request("10229876543210")) |> json_response(200)

    assert_receive :classic_tried
    assert Repo.get(User, user.id) == nil
    assert %FacebookDataDeletion{outcome: :deleted} = Repo.get(FacebookDataDeletion, code)
  end

  test "the status page says the request was processed, without personal data", %{conn: conn} do
    stub_classic(200)
    user = facebook_user("10229876543210")

    %{"url" => url} = conn |> deliver(signed_request("10229876543210")) |> json_response(200)

    html = build_conn() |> get(URI.parse(url).path) |> html_response(200)

    assert html =~ "Your data-deletion request is done"
    assert html =~ "Din begäran om radering är klar"
    assert html =~ ~s(data-state="processed")
    refute html =~ user.username
    refute html =~ user.email
    refute html =~ "10229876543210"

    html = build_conn() |> get(~p"/meta/data-deletion/not-a-code") |> html_response(404)
    assert html =~ "We don't know this confirmation code"
  end
end
