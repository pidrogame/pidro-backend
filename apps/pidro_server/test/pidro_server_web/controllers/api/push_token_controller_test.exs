defmodule PidroServerWeb.API.PushTokenControllerTest do
  use PidroServerWeb.ConnCase, async: true

  import PidroServer.AccountsFixtures

  alias PidroServer.Accounts.Token
  alias PidroServer.Push

  @token "ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]"
  @body %{
    "token" => @token,
    "platform" => "android",
    "install_id" => "install-1",
    "app_version" => "3.3.0",
    "app_build" => "15"
  }

  test "POST registers the phone: 201 the first time, 200 after", %{conn: conn} do
    user = guest_fixture()

    response = conn |> auth(user) |> post(~p"/api/v1/me/push-tokens", @body) |> json_response(201)
    assert_schema(response, "PushTokenResponse")

    assert response == %{
             "data" => %{
               "token" => @token,
               "platform" => "android",
               "install_id" => "install-1",
               "app_version" => "3.3.0",
               "app_build" => "15"
             }
           }

    # An app from before builds sends none, and clears the old one.
    again = @body |> Map.put("app_version", "3.3.1") |> Map.delete("app_build")
    response = conn |> auth(user) |> post(~p"/api/v1/me/push-tokens", again) |> json_response(200)
    assert response["data"]["app_version"] == "3.3.1"
    assert response["data"]["app_build"] == nil
    assert [%{app_version: "3.3.1", app_build: nil}] = Push.tokens_for(user.id)

    other = user_fixture()
    conn |> auth(other) |> post(~p"/api/v1/me/push-tokens", @body) |> json_response(200)
    assert Push.tokens_for(user.id) == []
    assert [_] = Push.tokens_for(other.id)
  end

  test "POST refuses what is not an Expo token from ios or android", %{conn: conn} do
    user = user_fixture()

    for body <- [
          %{@body | "token" => "not-a-token"},
          %{@body | "platform" => "web"},
          Map.delete(@body, "token")
        ] do
      response =
        conn |> auth(user) |> post(~p"/api/v1/me/push-tokens", body) |> json_response(422)

      assert_schema(response, "ValidationError")
      assert [%{"code" => code}] = response["errors"]
      assert code in ["token", "platform"]
    end

    assert Push.tokens_for(user.id) == []

    # A malformed build is only a missing label: the phone still gets push.
    for build <- ["15a", 15, "12345678901"] do
      conn
      |> auth(user)
      |> post(~p"/api/v1/me/push-tokens", %{@body | "app_build" => build})
      |> json_response(201)

      assert [%{app_build: nil}] = Push.tokens_for(user.id)
      Push.unregister(user, @token)
    end
  end

  test "DELETE forgets the caller's token with 204, also when it is already gone", %{conn: conn} do
    user = user_fixture()
    {:ok, _} = Push.register(user, @body)

    for _ <- 1..2 do
      assert conn
             |> auth(user)
             |> delete(~p"/api/v1/me/push-tokens/#{@token}")
             |> response(204) == ""
    end

    assert Push.tokens_for(user.id) == []
  end

  test "both need a signed-in player", %{conn: conn} do
    assert conn |> post(~p"/api/v1/me/push-tokens", @body) |> json_response(401)
    assert conn |> delete(~p"/api/v1/me/push-tokens/#{@token}") |> json_response(401)
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")

  defp assert_schema(response, name),
    do: OpenApiSpex.TestAssertions.assert_schema(response, name, PidroServerWeb.ApiSpec.spec())
end
