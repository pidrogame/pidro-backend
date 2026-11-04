defmodule PidroServerWeb.API.ProfileController do
  @moduledoc """
  API controller for the player profile screen.

  Serves the currently authenticated user's full profile in a single read:
  headline lifetime stats, skill tier + provisional state, veteran level/XP/
  title/progress, heritage badges, playstyle (aggression meter + avg winning
  bid), and mastery achievements.

  ## Authentication

  Requires a valid Bearer token in the Authorization header:
  `Authorization: Bearer <token>`. Validated via the Authenticate plug, which
  assigns `conn.assigns.current_user`.

  ## Skill is μ/σ-free

  The raw rating internals (`rating_mu`, `rating_sigma`, `rating_games_count`)
  are NEVER exposed. They feed `Rating.Tier.classify/1` server-side and are
  dropped by the fail-closed allowlist in `Profiles.public_profile/1`; only
  `skill: %{tier, provisional}` ships.

  ## OpenAPI Documentation

  - GET /api/v1/profile - Get current user's full profile screen

  All endpoints are tagged with "Profiles" in the OpenAPI specification.
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Accounts.Auth
  alias PidroServer.Profiles
  alias PidroServerWeb.Schemas.{ErrorSchemas, ProfileSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Profiles"])

  operation(:show,
    summary: "Get current user's player profile",
    description: """
    Retrieves the full profile screen for the currently authenticated user in a
    single read.

    This endpoint requires authentication. The Bearer token must be included in
    the Authorization header: `Authorization: Bearer <token>`

    Returns:
    - Headline lifetime stats (games/wins/losses/win_rate, first_seen, account age)
    - Skill (`tier` + `provisional` state)
    - Veteran progression (level, XP, title, progress)
    - Heritage badges (display list)
    - Playstyle (bidding win rate, aggression meter + label, avg winning bid)
    - Mastery achievements (earned + active catalog with an `earned` flag)

    The raw rating internals (μ/σ and the rated-game count) are intentionally
    NOT exposed — only the derived skill `tier` + `provisional` state. The
    exclusion is enforced by a fail-closed allowlist in the Profiles context.

    ## Error Responses
    - Returns 401 Unauthorized if token is missing, invalid, or expired
    """,
    security: [%{"bearer" => []}],
    responses: [
      ok:
        {"Player profile retrieved successfully", "application/json",
         ProfileSchemas.PlayerProfileResponse},
      unauthorized:
        {"Authentication required or invalid", "application/json",
         ErrorSchemas.unauthorized_error()}
    ]
  )

  operation(:update,
    summary: "Update current user's biography",
    security: [%{"bearer" => []}],
    request_body: {"Biography", "application/json", %OpenApiSpex.Schema{type: :object}},
    responses: [
      ok: {"Biography updated", "application/json", %OpenApiSpex.Schema{type: :object}},
      unprocessable_entity:
        {"Invalid biography", "application/json", ErrorSchemas.validation_error()}
    ]
  )

  operation(:public,
    summary: "Get a user's public profile",
    security: [%{"bearer" => []}],
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Public profile", "application/json", ProfileSchemas.PublicProfileResponse},
      not_found: {"User not found", "application/json", ErrorSchemas.not_found_error()}
    ]
  )

  operation(:by_slug,
    summary: "Get the public profile a share link names",
    security: [%{"bearer" => []}],
    parameters: [slug: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Public profile", "application/json", ProfileSchemas.PublicProfileResponse},
      not_found: {"User not found", "application/json", ErrorSchemas.not_found_error()}
    ]
  )

  @doc """
  Get the current user's full profile screen.

  ## Examples

      GET /api/v1/profile
      Authorization: Bearer <token>

      Response:
      {
        "data": {
          "user_id": "...",
          "games_played": 42,
          "skill": { "tier": "gold", "provisional": false },
          ...
        }
      }
  """
  def show(conn, _params) do
    user_id = conn.assigns.current_user.id

    conn
    |> put_status(:ok)
    |> json(%{data: Profiles.public_profile(user_id)})
  end

  def update(conn, params) do
    with {:ok, user} <- Auth.update_bio(conn.assigns.current_user.id, params) do
      json(conn, %{data: %{bio: user.bio}})
    end
  end

  def public(conn, %{"id" => id}) do
    with {:ok, profile} <- Auth.public_profile(id) do
      json(conn, %{data: with_player_sheet(profile, conn)})
    end
  end

  def by_slug(conn, %{"slug" => slug}) do
    with {:ok, profile} <- Auth.public_profile_by_slug(slug) do
      json(conn, %{data: with_player_sheet(profile, conn)})
    end
  end

  defp with_player_sheet(profile, conn),
    do: Map.merge(profile, Profiles.player_sheet(profile.user_id, conn.assigns.current_user.id))
end
