defmodule PidroServerWeb.API.PushTokenController do
  @moduledoc "The phone the app runs on, registered for push (PID-392)."
  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Push
  alias PidroServerWeb.Schemas.{ErrorSchemas, PushTokenSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Push"])
  security([%{"bearer_auth" => []}])

  operation(:create,
    summary: "Register this phone's Expo push token",
    description: """
    Registers the token for the caller, or refreshes it. A token another
    account had moves to the caller, a new sign-in on the same phone, and a
    token Expo had stopped is turned back on. Rate limited per player
    (`push_token`).
    """,
    request_body: {"Push token", "application/json", PushTokenSchemas.Request},
    responses: [
      created: {"Registered", "application/json", PushTokenSchemas.Response},
      ok: {"Already registered, now refreshed", "application/json", PushTokenSchemas.Response},
      unprocessable_entity:
        {"Not an Expo token, or no platform", "application/json", ErrorSchemas.validation_error()},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()},
      too_many_requests:
        {"Rate limited", "application/json", ErrorSchemas.too_many_requests_error()}
    ]
  )

  def create(conn, params) do
    with {:ok, token} <- Push.register(conn.assigns.current_user, params) do
      # The upsert keeps inserted_at, so only a new row has both stamps equal.
      status = if token.inserted_at == token.updated_at, do: :created, else: :ok

      conn
      |> put_status(status)
      |> json(%{data: Map.take(token, [:token, :platform, :install_id, :app_version])})
    end
  end

  operation(:delete,
    summary: "Stop push to this phone, on sign-out",
    description: "URL-encode the token. Answers 204 also when the caller had no such token.",
    parameters: [token: [in: :path, type: :string, required: true]],
    responses: [
      no_content: {"Forgotten", "application/json", %OpenApiSpex.Schema{type: :object}},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def delete(conn, %{"token" => token}) do
    :ok = Push.unregister(conn.assigns.current_user, token)
    send_resp(conn, :no_content, "")
  end
end
