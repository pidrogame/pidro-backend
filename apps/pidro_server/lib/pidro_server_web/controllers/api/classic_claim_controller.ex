defmodule PidroServerWeb.API.ClassicClaimController do
  @moduledoc "Verifies and redeems Classic account claims."

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Accounts.{AgeTerms, Auth, ClassicClaims, ClassicVerification, Token}
  alias PidroServerWeb.API.UserJSON
  alias PidroServerWeb.Schemas.{ClassicClaimSchemas, ErrorSchemas, UserSchemas}

  action_fallback PidroServerWeb.API.FallbackController
  tags(["Authentication"])

  operation(:verify,
    summary: "Verify ownership of a Classic account",
    description:
      "Validates a Classic password, Apple identity token, Facebook Graph access token, or Facebook Limited Login authentication token and returns a short-lived claim ticket.",
    request_body: {"Classic verification", "application/json", ClassicClaimSchemas.VerifyRequest},
    responses: [
      ok: {"Classic account verified", "application/json", ClassicClaimSchemas.VerifyResponse},
      unauthorized:
        {"Ownership could not be verified", "application/json", ErrorSchemas.unauthorized_error()},
      service_unavailable:
        {"Classic or identity provider unavailable", "application/json",
         ErrorSchemas.error_response()},
      unprocessable_entity:
        {"Missing install binding", "application/json", ErrorSchemas.validation_error()}
    ]
  )

  operation(:create,
    summary: "Attach a verified Classic account",
    description:
      "Redeems a short-lived claim ticket. A Bearer token attaches to that user; without one, the install-bound ticket creates a recoverable account.",
    request_body: {"Classic claim", "application/json", ClassicClaimSchemas.ClaimRequest},
    responses: [
      ok: {"Claim completed", "application/json", UserSchemas.UserWithTokenResponse},
      unauthorized:
        {"Invalid Bearer token", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden: {"Age is not eligible", "application/json", ErrorSchemas.error_response()},
      conflict:
        {"Classic account or provider already linked", "application/json",
         ErrorSchemas.conflict_error()},
      gone: {"Claim ticket expired", "application/json", ErrorSchemas.gone_error()},
      unprocessable_entity:
        {"Invalid claim or account data", "application/json", ErrorSchemas.validation_error()}
    ]
  )

  def verify(conn, params) do
    with {:ok, result} <- ClassicVerification.verify(params, conn.assigns[:current_user]) do
      json(conn, %{data: result})
    end
  end

  def create(conn, %{"ticket" => ticket} = params) do
    with {:ok, declaration} <- AgeTerms.parse(params),
         {:ok, claimed} <- ClassicClaims.redeem(ticket, conn.assigns[:current_user], params),
         {:ok, user} <- AgeTerms.store(claimed, declaration) do
      token = Token.generate(user)
      Auth.touch_last_seen(user)

      conn
      |> put_view(UserJSON)
      |> render(:show, %{
        user: user,
        token: token,
        linked_friend: claimed.linked_friend,
        classic_premium: claimed.classic_premium
      })
    end
  end

  def create(_conn, _params), do: {:error, :invalid_claim_ticket}
end
