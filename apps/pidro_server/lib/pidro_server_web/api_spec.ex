defmodule PidroServerWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for Pidro Server API.

  This module defines the OpenAPI 3.0 specification for all REST API endpoints.
  View the interactive documentation at `/api/openapi` in development mode.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias PidroServerWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [
        Server.from_endpoint(Endpoint)
      ],
      info: %Info{
        title: "Pidro Server API",
        version: "1.0.0",
        description: """
        # Pidro Server API Documentation

        A multiplayer card game server for Finnish Pidro built with Phoenix and Elixir.

        ## Features

        - User authentication with JWT tokens; direct or invited guest accounts upgraded in place
        - Room management (create, join, leave) and host controls (seat, lock, kick)
        - Invite links: one shareable code per table with an optional seat hint
        - Real-time gameplay via WebSocket channels
        - Game statistics tracking
        - Runtime-gated weekly leagues: raw `/api/v1/league` standings, results and monthly ribbons
        - Admin panel for monitoring

        ## Authentication

        Most endpoints require authentication using a JWT Bearer token obtained from the login endpoint.
        Include the token in the `Authorization` header:

        ```
        Authorization: Bearer <your-jwt-token>
        ```

        ## Rate Limiting

        `PidroServerWeb.Plugs.RateLimit` throttles the routes below. Production defaults from
        `config/config.exs`; development runs every limit at 10x.

        | Policy | Route | Limit | Keyed by |
        |--------|-------|-------|----------|
        | `login` | `POST /api/v1/auth/login` | 10 per minute | client IP |
        | `register` | `POST /api/v1/auth/register` | 10 per 10 minutes | client IP |
        | `password_reset` | `POST /api/v1/auth/password-reset` | 3 per 15 minutes | client IP |
        | `password_reset_identifier` | `POST /api/v1/auth/password-reset` | 3 per hour | hashed `identifier`/`email` param |
        | `password_reset_confirm` | `POST /api/v1/auth/password-reset/confirm` | 5 per 15 minutes | client IP |
        | `room_create` | `POST /api/v1/rooms` | 10 per minute | authenticated user |
        | `room_lookup` | `GET /api/v1/rooms/:code` | 120 per minute | client IP |
        | `room_join` | `POST /api/v1/rooms/:code/join` | 30 per minute | authenticated user |
        | `invite_mint` | `POST /api/v1/rooms/:code/invites`, `POST /api/v1/invites/:code/regenerate` | 10 per minute | authenticated user |
        | `invite_preview` | `GET /api/v1/invites/:code` | 60 per minute | client IP |
        | `invite_capture` | `POST /j/:code/deferred`, `POST /play/:slug/deferred` | 20 per 30 minutes | client IP |
        | `invite_capture_code` | `POST /j/:code/deferred` | 200 per 30 minutes | hashed invite code |
        | `friend_capture_slug` | `POST /play/:slug/deferred` | 200 per 30 minutes | hashed friend slug |
        | `invite_deferred` | `POST /api/v1/invites/deferred` | 5 per 30 minutes | client IP |
        | `invite_deferred_install` | `POST /api/v1/invites/deferred` | 2 per 30 minutes | hashed `install_id` |
        | `invite_redeem` | `POST /api/v1/invites/:code/redeem` | 10 per minute | authenticated user |
        | `guest_create` | `POST /api/v1/auth/guest` | 10 per hour | client IP |
        | `guest_create_daily` | `POST /api/v1/auth/guest` | 40 per day | client IP |
        | `guest_create_install` | `POST /api/v1/auth/guest` | 3 per hour | hashed `install_id` param (skipped when absent) |
        | `auth_upgrade` | `POST /api/v1/auth/upgrade` | 10 per 10 minutes | client IP |
        | `auth_age` | `POST /api/v1/auth/age` | 10 per 10 minutes | authenticated user |
        | `provider_auth` | `POST /api/v1/auth/apple`, `POST /api/v1/auth/facebook` | 10 per minute | client IP |
        | `classic_claim` | `POST /api/v1/classic/claim` | 10 per 10 minutes | client IP |

        A request over its limit is answered `429 Too Many Requests` with a `Retry-After` header
        (whole seconds until the window resets, at least 1) and the error body below with code
        `RATE_LIMITED`. Wait for `Retry-After` before retrying. Limits are per node and per fixed
        window: counters reset when the node restarts, and up to twice the limit can pass across a
        window boundary. Operators tune them with `RATE_LIMIT_<POLICY>_LIMIT` and
        `RATE_LIMIT_<POLICY>_SCALE_MS`; there is no off switch.

        ## WebSocket Channels

        For real-time gameplay, connect to WebSocket channels after authenticating:

        - `lobby` - Lobby updates and room list
        - `game:<room_code>` - Real-time game events for a specific room

        See the WebSocket documentation for detailed event specifications.

        ## Error Responses

        All errors follow a consistent format:

        ```json
        {
          "errors": [
            {
              "code": "ERROR_CODE",
              "title": "Human-readable title",
              "detail": "Detailed error message"
            }
          ]
        }
        ```

        Common HTTP status codes:
        - `200 OK` - Request succeeded
        - `201 Created` - Resource created successfully
        - `204 No Content` - Request succeeded with no response body
        - `401 Unauthorized` - Authentication required or token invalid
        - `403 Forbidden` - Not the host (`NOT_OWNER`) or kicked from the table (`KICKED`)
        - `404 Not Found` - Resource not found (`INVITATION_GONE` when declining a seat no longer held for you)
        - `409 Conflict` - The target refuses the action in its current state (`SEAT_TAKEN` with `next_open`, `TABLE_FULL`, `ROOM_NOT_WAITING`, `INVITE_LIMIT`, `NOT_A_GUEST`, `EMAIL_TAKEN`, `USERNAME_TAKEN`)
        - `410 Gone` - The invite or its table no longer accepts players (`TABLE_STARTED`, `TABLE_CLOSED`, `INVITE_EXPIRED`, `INVITE_REVOKED`, `INVITE_MOVED` with `next_code`)
        - `422 Unprocessable Entity` - Validation error
        - `423 Locked` - The host locked the table (`TABLE_LOCKED`)
        - `429 Too Many Requests` - Rate limit exceeded; honour `Retry-After`
        - `503 Service Unavailable` - No free room code could be allocated (`ROOM_CODE_EXHAUSTED`); retry shortly
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearer_auth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description: "JWT token obtained from login endpoint"
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
