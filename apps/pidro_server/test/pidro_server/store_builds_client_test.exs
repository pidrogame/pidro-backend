defmodule PidroServer.StoreBuilds.ClientTest do
  use ExUnit.Case, async: true
  alias PidroServer.StoreBuilds.Client

  setup do
    fixture = File.read!(Path.expand("../fixtures/store_builds.json", __DIR__)) |> Jason.decode!()
    %{fixture: fixture}
  end

  test "ASC signs raw ES256, follows pagination and reads Friends separately from Team", %{
    fixture: f
  } do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

    config = [
      asc_key_id: "key-id",
      asc_issuer_id: "issuer-id",
      asc_private_key: pem,
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
      [header, claims, signature] = String.split(jwt, ".")
      assert decode(header)["kid"] == "key-id"
      assert decode(claims)["iss"] == "issuer-id"
      assert decode(claims)["aud"] == "appstoreconnect-v1"
      assert decode(claims)["exp"] - decode(claims)["iat"] <= 1200
      <<r::256, s::256>> = Base.url_decode64!(signature, padding: false)
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      assert :public_key.verify(header <> "." <> claims, :sha256, der, key)

      body =
        case conn.request_path do
          "/v1/builds" ->
            if conn.query_string == "page=2" do
              %{f["asc"] | "data" => Enum.drop(f["asc"]["data"], 1)}
            else
              %{
                f["asc"]
                | "data" => Enum.take(f["asc"]["data"], 1),
                  "links" => %{"next" => "https://api.appstoreconnect.apple.com/v1/builds?page=2"}
              }
            end

          "/v1/apps/6816832730/betaGroups" ->
            f["groups"]

          "/v1/betaGroups/friends/builds" ->
            f["friends"]

          "/v1/betaGroups/team/builds" ->
            f["team"]
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, %{newest: %{number: "10"}, live: %{version: "3.2.1", number: "7"}}} =
             Client.fetch("ios", config)
  end

  test "expired and internal-only builds are never live for Friends", %{fixture: f} do
    expired = put_in(f, ["asc", "data", Access.at(2), "attributes", "expired"], true)
    assert Client.parse_asc(expired["asc"], f["friends"], f["team"]).live == nil
    assert Client.parse_asc(f["asc"], %{"data" => []}, f["team"]).live == nil
  end

  test "Play signs RS256 and deletes its edit on success, HTTP failure, exception and malformed data",
       %{fixture: f} do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    config = [
      play_service_account_json:
        Jason.encode!(%{client_email: "test@example.com", private_key: pem}),
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    parent = self()

    for outcome <- [
          :success,
          :http_error,
          :exception,
          :malformed,
          :cleanup_error,
          :bad_token,
          :bad_edit
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/token"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            [header, claims, signature] = URI.decode_query(body)["assertion"] |> String.split(".")
            assert decode(header)["alg"] == "RS256"
            assert decode(claims)["scope"] == "https://www.googleapis.com/auth/androidpublisher"
            assert decode(claims)["aud"] == "https://oauth2.googleapis.com/token"

            assert :public_key.verify(
                     header <> "." <> claims,
                     :sha256,
                     Base.url_decode64!(signature, padding: false),
                     key
                   )

            Req.Test.json(
              conn,
              if(outcome == :bad_token, do: %{}, else: %{access_token: "fake-token"})
            )

          {"POST", "/androidpublisher/v3/applications/com.oneapps.pidro.beta/edits"} ->
            Req.Test.json(conn, if(outcome == :bad_edit, do: %{}, else: %{id: "throwaway"}))

          {"GET",
           "/androidpublisher/v3/applications/com.oneapps.pidro.beta/edits/throwaway/tracks"} ->
            case outcome do
              :http_error -> Plug.Conn.send_resp(conn, 403, "secret response must not appear")
              :exception -> raise "secret exception must not appear"
              :malformed -> Req.Test.json(conn, %{unexpected: true})
              _ -> Req.Test.json(conn, f["play"])
            end

          {"DELETE", "/androidpublisher/v3/applications/com.oneapps.pidro.beta/edits/throwaway"} ->
            send(parent, {:deleted, outcome})
            Plug.Conn.send_resp(conn, if(outcome == :cleanup_error, do: 500, else: 204), "")
        end
      end)

      result = Client.fetch("android", config)
      if outcome not in [:bad_token, :bad_edit], do: assert_received({:deleted, ^outcome})

      if outcome == :success do
        assert {:ok, %{live: %{version: "3.2.4", number: "9", track: "beta"}}} = result
      else
        assert {:error, error} = result
        refute error =~ "secret"
      end
    end
  end

  test "a completed internal release or a newer production draft is not open testing", %{
    fixture: f
  } do
    play =
      put_in(f["play"], ["tracks", Access.at(0), "releases", Access.at(0), "versionCodes"], ["11"])

    assert Client.parse_play(play).live.number == "9"
    assert Client.parse_play(play).newest.number == "9"
    play = put_in(play, ["tracks", Access.at(2), "releases", Access.at(0), "status"], "draft")
    assert Client.parse_play(play).live == nil
  end

  test "arbitrary Play release names are displayed but never used as versions", %{fixture: f} do
    for name <- ["November beta", "3.2.4-beta.1", "3.2.4+9"] do
      play = put_in(f["play"], ["tracks", Access.at(2), "releases", Access.at(0), "name"], name)
      assert %{live: %{version: nil, label: ^name}} = Client.parse_play(play)
    end
  end

  defp decode(value), do: value |> Base.url_decode64!(padding: false) |> Jason.decode!()
end
