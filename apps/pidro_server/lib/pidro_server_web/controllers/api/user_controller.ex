defmodule PidroServerWeb.API.UserController do
  @moduledoc """
  API controller for user-related operations.

  This controller handles user-specific functionality including statistics
  and user data retrieval. All endpoints are protected and require authentication
  via Bearer token in the Authorization header.

  ## Authentication

  All endpoints in this controller require a valid Bearer token in the
  Authorization header. Tokens are validated via the Authenticate plug.

  ## OpenAPI Documentation

  This controller includes OpenAPI 3.0 specifications for all endpoints:
  - GET /api/v1/users/me/stats - Get current user's game statistics
  - POST /api/v1/me/entitlements/refresh - Sync Premium from RevenueCat

  All endpoints are tagged with "Users" in the OpenAPI specification.
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Entitlements
  alias PidroServer.RevenueCat
  alias PidroServer.Stats
  alias PidroServerWeb.Schemas.{UserSchemas, ErrorSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Users"])

  operation(:stats,
    summary: "Get current user's game statistics",
    description: """
    Retrieves aggregated game statistics for the currently authenticated user.

    This endpoint requires authentication. The Bearer token must be included
    in the Authorization header: `Authorization: Bearer <token>`

    Returns comprehensive statistics including:
    - Total games played
    - Total wins and losses
    - Win rate (as a decimal from 0.0 to 1.0)
    - Total time spent playing (in seconds)
    - Average bid amount across all games

    All statistics are calculated from the user's complete game history and
    updated in real-time based on their participation in games.

    ## Error Responses
    - Returns 401 Unauthorized if token is missing, invalid, or expired
    """,
    security: [%{"bearer" => []}],
    responses: [
      ok:
        {"User statistics retrieved successfully", "application/json",
         UserSchemas.UserStatsResponse},
      unauthorized:
        {"Authentication required or invalid", "application/json",
         ErrorSchemas.unauthorized_error()}
    ]
  )

  @doc """
  Get current user's game statistics.

  Returns aggregated stats including:
  - Total games played
  - Wins/losses
  - Win rate
  - Total duration played
  - Average bid amount

  ## Examples

      GET /api/v1/users/me/stats
      Authorization: Bearer <token>

      Response:
      {
        "data": {
          "games_played": 42,
          "wins": 25,
          "losses": 17,
          "win_rate": 0.595,
          "total_duration_seconds": 12600,
          "average_bid": 10.5
        }
      }
  """
  def stats(conn, _params) do
    user_id = conn.assigns.current_user.id
    stats = Stats.get_user_stats(user_id)

    conn
    |> put_status(:ok)
    |> json(%{data: stats})
  end

  operation(:refresh_entitlements,
    summary: "Sync the current user's Premium from RevenueCat",
    description: """
    Asks RevenueCat for the player's purchases and answers the same Premium
    fields as `GET /api/v1/auth/me`. Call it after a purchase or a restore
    and wait for its answer before hiding ads.

    ## Error Responses
    - 401 when the token is missing or invalid
    - 429 `RATE_LIMITED` past 6 per minute per player
    - 503 `REVENUECAT_NOT_CONFIGURED` when the server has no RevenueCat keys
    - 503 `PREMIUM_UNAVAILABLE` when RevenueCat could not be reached
    """,
    security: [%{"bearer_auth" => []}],
    responses: [
      ok: {"Premium fields after the sync", "application/json", UserSchemas.PremiumResponse},
      unauthorized:
        {"Authentication required or invalid", "application/json",
         ErrorSchemas.unauthorized_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()},
      service_unavailable:
        {"RevenueCat is not configured or not reachable", "application/json",
         ErrorSchemas.error_response()}
    ]
  )

  @doc "Syncs the current user's Premium from RevenueCat and answers the Premium fields."
  def refresh_entitlements(conn, _params) do
    user = conn.assigns.current_user

    with :ok <- if(RevenueCat.configured?(), do: :ok, else: {:error, :revenuecat_not_configured}),
         {:ok, _row} <- sync(user) do
      json(conn, %{data: Entitlements.premium_fields(user)})
    end
  end

  defp sync(user) do
    case Entitlements.sync_from_revenuecat(user.id) do
      {:ok, row} -> {:ok, row}
      {:error, _reason} -> {:error, :premium_unavailable}
    end
  end
end
