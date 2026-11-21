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

    # The beta store records and tracks: runtime.exs defaults with no env set.
    config =
      Keyword.merge(Application.fetch_env!(:pidro_server, Client),
        asc_key_id: "key-id",
        asc_issuer_id: "issuer-id",
        asc_private_key: pem,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

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

    # The beta store records and tracks: runtime.exs defaults with no env set.
    config =
      Keyword.merge(Application.fetch_env!(:pidro_server, Client),
        play_service_account_json:
          Jason.encode!(%{client_email: "test@example.com", private_key: pem}),
        req_options: [plug: {Req.Test, __MODULE__}]
      )

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

    assert Client.parse_play(play, "beta").live.number == "9"
    assert Client.parse_play(play, "beta").newest.number == "9"
    play = put_in(play, ["tracks", Access.at(2), "releases", Access.at(0), "status"], "draft")
    assert Client.parse_play(play, "beta").live == nil
  end

  test "arbitrary Play release names are displayed but never used as versions", %{fixture: f} do
    for name <- ["November beta", "3.2.4-beta.1", "3.2.4+9"] do
      play = put_in(f["play"], ["tracks", Access.at(2), "releases", Access.at(0), "name"], name)
      assert %{live: %{version: nil, label: ^name}} = Client.parse_play(play, "beta")
    end
  end

  describe "switch-day production records and tracks" do
    setup do
      %{
        production:
          Keyword.merge(Application.fetch_env!(:pidro_server, Client),
            asc_app_id: "1137091987",
            play_package: "com.oneapps.pidro",
            ios_track: "app_store",
            play_track: "production",
            req_options: [plug: {Req.Test, __MODULE__}]
          )
      }
    end

    test "iPhone reads the App Store versions of the production app: live and in review", %{
      production: production
    } do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

      version = fn id, string, state, created, build ->
        %{
          "type" => "appStoreVersions",
          "id" => id,
          "attributes" => %{
            "versionString" => string,
            "appVersionState" => state,
            "createdDate" => created
          },
          "relationships" => %{
            "build" => %{"data" => build && %{"type" => "builds", "id" => build}}
          }
        }
      end

      build = fn id, number ->
        %{"type" => "builds", "id" => id, "attributes" => %{"version" => number}}
      end

      # Apple's order is not newest first; the live version sits between two others.
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/apps/1137091987/appStoreVersions"

        assert URI.decode_query(conn.query_string) == %{
                 "filter[platform]" => "IOS",
                 "include" => "build",
                 "limit" => "200"
               }

        Req.Test.json(conn, %{
          "data" => [
            version.("v323", "3.2.3", "REPLACED_WITH_NEW_VERSION", "2026-10-01T07:00:00Z", "b8"),
            version.("v330", "3.3.0", "WAITING_FOR_REVIEW", "2026-12-01T07:00:00Z", "b12"),
            version.("v324", "3.2.4", "READY_FOR_DISTRIBUTION", "2026-11-01T07:00:00Z", "b9")
          ],
          "included" => [build.("b8", "8"), build.("b12", "12"), build.("b9", "9")]
        })
      end)

      config =
        Keyword.merge(production, asc_key_id: "k", asc_issuer_id: "i", asc_private_key: pem)

      assert {:ok, %{newest: newest, live: live}} = Client.fetch("ios", config)

      assert {newest.version, newest.number, newest.state} ==
               {"3.3.0", "12", "WAITING_FOR_REVIEW"}

      assert {live.version, live.number} == {"3.2.4", "9"}
      refute newest.friends or newest.team
    end

    test "a version without a build is the newest; none live leaves live empty" do
      body = %{
        "data" => [
          %{
            "id" => "v1",
            "attributes" => %{
              "versionString" => "4.0.0",
              "appVersionState" => "PREPARE_FOR_SUBMISSION",
              "createdDate" => "2026-11-20T07:00:00Z"
            },
            "relationships" => %{"build" => %{"data" => nil}}
          }
        ]
      }

      assert %{newest: %{version: "4.0.0", number: nil}, live: nil} = Client.parse_app_store(body)
    end

    test "Android reads the production package and its production track, not the beta track", %{
      production: production,
      fixture: f
    } do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      edits = "/androidpublisher/v3/applications/com.oneapps.pidro/edits"
      {tracks, edit} = {edits <> "/throwaway/tracks", edits <> "/throwaway"}

      completed =
        put_in(
          f["play"],
          ["tracks", Access.at(0), "releases", Access.at(0), "status"],
          "completed"
        )

      for {play, live} <- [{f["play"], nil}, {completed, "8"}] do
        Req.Test.stub(__MODULE__, fn conn ->
          case {conn.method, conn.request_path} do
            {"POST", "/token"} -> Req.Test.json(conn, %{access_token: "fake-token"})
            {"POST", ^edits} -> Req.Test.json(conn, %{id: "throwaway"})
            {"GET", ^tracks} -> Req.Test.json(conn, play)
            {"DELETE", ^edit} -> Plug.Conn.send_resp(conn, 204, "")
          end
        end)

        config =
          Keyword.put(
            production,
            :play_service_account_json,
            Jason.encode!(%{client_email: "test@example.com", private_key: pem})
          )

        # The beta track's completed 3.2.4 (9) is never production's live build.
        assert {:ok, result} = Client.fetch("android", config)
        assert result.live[:number] == live
        assert result.newest.number == "9" and result.newest.track == "internal"
      end
    end
  end

  defp decode(value), do: value |> Base.url_decode64!(padding: false) |> Jason.decode!()
end
