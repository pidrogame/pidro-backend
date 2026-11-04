defmodule PidroServerWeb.API.LeagueController do
  @moduledoc "The league screen and account-owned acknowledgments."
  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias PidroServer.Leagues
  alias PidroServerWeb.{ErrorContract, Schemas.ErrorSchemas, Schemas.LeagueSchemas}
  alias PidroServerWeb.Schemas.BlockSchemas
  action_fallback PidroServerWeb.API.FallbackController

  plug :require_account when action in [:hidden, :intro_seen, :seen]
  tags(["Leagues"])
  security([%{"bearer_auth" => []}])

  operation(:show,
    summary: "Read the weekly league, results and ribbons",
    responses: [
      ok: {"League", "application/json", LeagueSchemas.Response},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def show(conn, _params), do: json(conn, Leagues.show(conn.assigns.current_user))

  operation(:hidden,
    summary: "Set league opt-out",
    request_body: {"Hidden", "application/json", LeagueSchemas.Hidden},
    responses: [
      ok: {"League", "application/json", LeagueSchemas.Response},
      forbidden: {"Account required", "application/json", BlockSchemas.Error},
      unprocessable_entity:
        {"Invalid hidden flag", "application/json", ErrorSchemas.validation_error()},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def hidden(conn, params) do
    with {:ok, _} <-
           Leagues.hidden(conn.assigns.current_user, params["hidden"], DateTime.utc_now()) do
      show(conn, %{})
    end
  end

  operation(:intro_seen,
    summary: "Dismiss the league introduction",
    responses: [
      no_content: "Dismissed",
      forbidden: {"Account required", "application/json", BlockSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def intro_seen(conn, _params) do
    with {:ok, _} <- Leagues.intro_seen(conn.assigns.current_user),
         do: send_resp(conn, :no_content, "")
  end

  operation(:seen,
    summary: "Acknowledge an owned weekly result",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Seen",
      not_found: {"Result unavailable", "application/json", ErrorSchemas.not_found_error()},
      forbidden: {"Account required", "application/json", BlockSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def seen(conn, %{"id" => id}) do
    with :ok <- Leagues.seen(conn.assigns.current_user.id, id),
         do: send_resp(conn, :no_content, "")
  end

  defp require_account(%{assigns: %{current_user: %{guest: true}}} = conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> json(ErrorContract.add(%{error: "ACCOUNT_REQUIRED"}, :account_required))
    |> halt()
  end

  defp require_account(conn, _opts), do: conn
end
