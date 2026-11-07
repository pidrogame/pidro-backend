defmodule PidroServerWeb.API.FallbackController do
  @moduledoc """
  Fallback controller for handling errors in API responses.

  This controller implements the fallback pattern used in Phoenix API applications.
  It serves as a centralized error handler for all API endpoints, converting various
  error tuples into properly formatted JSON responses with appropriate HTTP status codes.

  ## Pattern Matches

  Handles the following error types:
  - `{:error, %Ecto.Changeset{}}` - Validation errors from Ecto changesets
  - `{:error, :invalid_credentials}` - Authentication failures
  - `{:error, :not_found}` - Resource not found errors
  - Invite and host-control atoms (KTD5): `:table_full`, `:room_not_waiting`,
    `:invite_limit`, `:not_a_guest`, `:email_taken`, `:username_taken` and
    `:creation_conflict` answer 409; `:table_started`, `:table_closed`,
    `:invite_expired`, `:invite_revoked` and `{:invite_moved, next_code}` answer
    410; `:table_locked` answers 423; `:kicked` answers 403;
    `:no_seat_for_you` answers 409; `{:seat_taken, next_open}` answers 409 with
    the open positions while the bare `:seat_taken` keeps its 422 for room joins
  - `{:error, {:invalid_room_params, errors}}` - Room config validation errors;
    answers 422 with one entry per error and the field path as the code
  - Any other atom answers 422 with the atom upcased as the code
  """

  use PidroServerWeb, :controller

  import Phoenix.Controller, except: [json: 2]
  alias PidroServerWeb.ErrorContract

  @doc """
  Handles Ecto changeset validation errors.

  Extracts all errors from the changeset and formats them into a JSON response.
  Each error includes a code, humanized title, and detailed message.

  Returns HTTP 422 (Unprocessable Entity).

  ## Examples

  When called with a changeset error, returns:

      %{
        errors: [
          %{
            code: "username",
            title: "Username",
            detail: "has already been taken"
          }
        ]
      }
  """
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        detail =
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", to_string(value))
          end)

        {detail, opts[:code]}
      end)

    formatted_errors =
      Enum.map(errors, fn {field, messages} ->
        Enum.map(messages, fn {detail, code} ->
          %{
            code: to_string(code || field),
            title: humanize_field(field),
            detail: detail
          }
        end)
      end)
      |> List.flatten()

    conn
    |> put_status(:unprocessable_entity)
    |> Phoenix.Controller.json(ErrorContract.validation(%{errors: formatted_errors}, changeset))
  end

  def call(conn, {:error, :invalid_credentials}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      errors: [
        %{
          code: "INVALID_CREDENTIALS",
          title: "Invalid credentials",
          detail: "Username or password is incorrect"
        }
      ]
    })
  end

  def call(conn, {:error, :mail_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      errors: [
        %{
          code: "MAIL_UNAVAILABLE",
          title: "Mail unavailable",
          detail: "Your message could not be sent right now"
        }
      ]
    })
  end

  def call(conn, {:error, :revenuecat_not_configured}) do
    error(
      conn,
      :service_unavailable,
      "REVENUECAT_NOT_CONFIGURED",
      "Premium unavailable",
      "This server has no RevenueCat keys, so it cannot check Premium"
    )
  end

  def call(conn, {:error, :premium_unavailable}) do
    error(
      conn,
      :service_unavailable,
      "PREMIUM_UNAVAILABLE",
      "Premium unavailable",
      "Premium could not be checked right now. Try again shortly."
    )
  end

  def call(conn, {:error, :classic_account_not_found}) do
    error(
      conn,
      :not_found,
      "CLASSIC_ACCOUNT_NOT_FOUND",
      "Classic account not found",
      "No Classic account was found with that username or email"
    )
  end

  def call(conn, {:error, :classic_email_missing}) do
    error(
      conn,
      :unprocessable_entity,
      "CLASSIC_EMAIL_MISSING",
      "Classic email missing",
      "This Classic account has no email address. Contact support for help."
    )
  end

  def call(conn, {:error, :classic_code_invalid}) do
    error(
      conn,
      :unauthorized,
      "CLASSIC_CODE_INVALID",
      "Invalid Classic code",
      "That code didn't work. Ask for a new one."
    )
  end

  def call(conn, {:error, :provider_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      errors: [
        %{
          code: "PROVIDER_UNAVAILABLE",
          title: "Sign-in unavailable",
          detail: "The identity provider is temporarily unavailable"
        }
      ]
    })
  end

  def call(conn, {:error, :account_inactive}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: [
        %{
          code: "ACCOUNT_INACTIVE",
          title: "Classic account inactive",
          detail: "This Classic account is switched off. Contact support to reactivate it."
        }
      ]
    })
  end

  def call(conn, {:error, :claim_binding_required}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "CLAIM_BINDING_REQUIRED",
          title: "Install identifier required",
          detail: "Send an install identifier or sign in before verifying the Classic account"
        }
      ]
    })
  end

  def call(conn, {:error, {:already_claimed, method}})
      when method in [:password, :apple, :facebook, nil] do
    error = %{
      code: "ALREADY_CLAIMED",
      title: "Account already linked",
      detail: "This Classic account belongs to another account"
    }

    conn
    |> put_status(:conflict)
    |> json(%{
      errors: [if(method, do: Map.put(error, :action, sign_in_action(method)), else: error)]
    })
  end

  def call(conn, {:error, :user_already_claimed}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: [
        %{
          code: "USER_ALREADY_CLAIMED",
          title: "Classic profile already linked",
          detail: "This account already has a different Classic profile"
        }
      ]
    })
  end

  def call(conn, {:error, :provider_already_linked}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: [
        %{
          code: "PROVIDER_ALREADY_LINKED",
          title: "Sign-in already linked",
          detail: "This provider identity cannot be linked to this account"
        }
      ]
    })
  end

  def call(conn, {:error, :claim_ticket_expired}) do
    conn
    |> put_status(:gone)
    |> json(%{
      errors: [
        %{
          code: "CLAIM_TICKET_EXPIRED",
          title: "Claim expired",
          detail: "Verify the Classic account again"
        }
      ]
    })
  end

  def call(conn, {:error, :invalid_or_expired_password_reset_token}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "INVALID_OR_EXPIRED_PASSWORD_RESET_TOKEN",
          title: "Invalid reset link",
          detail: "Password reset link is invalid or expired"
        }
      ]
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "NOT_FOUND",
          title: "Not found",
          detail: "Resource not found"
        }
      ]
    })
  end

  # The room exists but is moving to another node (a deploy): try again soon.
  def call(conn, {:error, :room_moving}) do
    error(
      conn,
      :service_unavailable,
      "GAME_UNAVAILABLE",
      "Room is moving",
      "This table is moving to a new server. Try again in a moment."
    )
  end

  def call(conn, {:error, :room_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_FOUND",
          title: "Room not found",
          detail: "The requested room does not exist"
        }
      ]
    })
  end

  def call(conn, {:error, :invitation_gone}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "INVITATION_GONE",
          title: "Invitation gone",
          detail: "No seat is held for you here"
        }
      ]
    })
  end

  def call(conn, {:error, :room_full}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_FULL",
          title: "Room full",
          detail: "Room already has 4 players"
        }
      ]
    })
  end

  def call(conn, {:error, :account_required}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: [
        %{
          code: "ACCOUNT_REQUIRED",
          title: "Account required",
          detail: "Create an account to join an open seat"
        }
      ]
    })
  end

  def call(conn, {:error, :already_in_room}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_IN_ROOM",
          title: "Already in room",
          detail: "User is already in another room"
        }
      ]
    })
  end

  def call(conn, {:error, :already_in_this_room}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_IN_THIS_ROOM",
          title: "Already in this room",
          detail: "User is already in this room"
        }
      ]
    })
  end

  def call(conn, {:error, :not_in_room}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "NOT_IN_ROOM",
          title: "Not in room",
          detail: "Player is not in any room"
        }
      ]
    })
  end

  def call(conn, {:error, :room_not_available_for_spectators}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_AVAILABLE_FOR_SPECTATORS",
          title: "Room not available for spectators",
          detail: "Can only spectate games that are playing or finished"
        }
      ]
    })
  end

  def call(conn, {:error, :spectators_full}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SPECTATORS_FULL",
          title: "Spectators full",
          detail: "Room has reached maximum number of spectators"
        }
      ]
    })
  end

  def call(conn, {:error, :already_spectating}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_SPECTATING",
          title: "Already spectating",
          detail: "User is already spectating a room"
        }
      ]
    })
  end

  def call(conn, {:error, :not_spectating}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "NOT_SPECTATING",
          title: "Not spectating",
          detail: "User is not spectating any room"
        }
      ]
    })
  end

  def call(conn, {:error, {:seat_requires_games, min_games, games_played}}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "SEAT_REQUIRES_GAMES", min_games: min_games, games_played: games_played})
  end

  def call(conn, {:error, :seat_requires_password}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: [
        %{
          code: "SEAT_REQUIRES_PASSWORD",
          title: "Seat requires password",
          detail: "This seat needs the table's password"
        }
      ]
    })
  end

  def call(conn, {:error, :profile_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      errors: [
        %{
          code: "PROFILE_UNAVAILABLE",
          title: "Profile unavailable",
          detail: "Player eligibility could not be checked; please try again shortly"
        }
      ]
    })
  end

  def call(conn, {:error, :seat_taken}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_TAKEN",
          title: "Seat taken",
          detail: "The requested seat is already occupied",
          available_positions: []
        }
      ]
    })
  end

  def call(conn, {:error, :team_full}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "TEAM_FULL",
          title: "Team full",
          detail: "The requested team is fully occupied",
          available_positions: []
        }
      ]
    })
  end

  def call(conn, {:error, :invalid_position}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "INVALID_POSITION",
          title: "Invalid position",
          detail: "The position parameter is invalid"
        }
      ]
    })
  end

  def call(conn, {:error, :room_not_available}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_AVAILABLE",
          title: "Room not available",
          detail: "Room is not available for joining"
        }
      ]
    })
  end

  def call(conn, {:error, :not_owner}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: [
        %{
          code: "NOT_OWNER",
          title: "Not owner",
          detail: "Only the room owner can perform this action"
        }
      ]
    })
  end

  def call(conn, {:error, :room_not_playing}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_PLAYING",
          title: "Room not playing",
          detail: "Room must be in playing status for this action"
        }
      ]
    })
  end

  def call(conn, {:error, :seat_not_bot_substitute}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_NOT_BOT_SUBSTITUTE",
          title: "Seat not bot substitute",
          detail: "The seat must be occupied by a substitute bot"
        }
      ]
    })
  end

  def call(conn, {:error, :seat_not_vacant}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_NOT_VACANT",
          title: "Seat not vacant",
          detail: "The seat must be vacant to close it"
        }
      ]
    })
  end

  def call(conn, {:error, :already_seated}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_SEATED",
          title: "Already seated",
          detail: "Player is already seated in this room"
        }
      ]
    })
  end

  def call(conn, {:error, :no_vacant_seat}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "NO_VACANT_SEAT",
          title: "No vacant seat",
          detail: "No vacant seat is available for joining"
        }
      ]
    })
  end

  # ==================== Invite and host-control errors (KTD5) ====================
  #
  # Every clause below must stay above the `is_atom(reason)` catch-all, which
  # would answer 422. The bare `:seat_taken` atom keeps its 422 above so
  # `POST /rooms/:code/join` is unchanged; the tuple form is the invite redeem
  # answer (R5).

  def call(conn, {:error, :user_not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "USER_NOT_FOUND"})
  end

  def call(conn, {:error, {:seat_taken, next_open}}) when is_list(next_open) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: [
        %{
          code: "SEAT_TAKEN",
          title: "Seat taken",
          detail: "The requested seat is already occupied",
          next_open: Enum.map(next_open, &Atom.to_string/1)
        }
      ]
    })
  end

  def call(conn, {:error, :no_seat_for_you}) do
    conflict(
      conn,
      "NO_SEAT_FOR_YOU",
      "No seat for you",
      "Your friend's table has no open seat you can take"
    )
  end

  def call(conn, {:error, :table_full}) do
    conflict(conn, "TABLE_FULL", "Table full", "Every seat at the table is taken")
  end

  def call(conn, {:error, :room_not_waiting}) do
    conflict(
      conn,
      "ROOM_NOT_WAITING",
      "Room not waiting",
      "The room is no longer waiting for players"
    )
  end

  def call(conn, {:error, :invite_limit}) do
    conflict(conn, "INVITE_LIMIT", "Invite limit", "This room has reached its invite limit")
  end

  def call(conn, {:error, :not_a_guest}) do
    conflict(conn, "NOT_A_GUEST", "Not a guest", "Only a guest account can be upgraded")
  end

  def call(conn, {:error, :email_taken}) do
    conflict(conn, "EMAIL_TAKEN", "Email taken", "Another account uses that email address")
  end

  def call(conn, {:error, :username_taken}) do
    conflict(conn, "USERNAME_TAKEN", "Username taken", "Another account uses that username")
  end

  def call(conn, {:error, :creation_conflict}) do
    conflict(
      conn,
      "CREATION_CONFLICT",
      "Creation token already used",
      "Generate a new creation token and try again"
    )
  end

  def call(conn, {:error, :age_already_set}) do
    conflict(conn, "AGE_ALREADY_SET", "Age already set", "The account's age band is already set")
  end

  def call(conn, {:error, :age_not_eligible}) do
    error(
      conn,
      :forbidden,
      "AGE_NOT_ELIGIBLE",
      "Age not eligible",
      "You must be at least 13 years old to use Pidro"
    )
  end

  def call(conn, {:error, :table_started}) do
    gone(conn, "TABLE_STARTED", "Table started", "The game at this table has already started")
  end

  def call(conn, {:error, :table_closed}) do
    gone(conn, "TABLE_CLOSED", "Table closed", "The table this invite opened no longer exists")
  end

  def call(conn, {:error, :invite_expired}) do
    gone(conn, "INVITE_EXPIRED", "Invite expired", "This invite has expired")
  end

  def call(conn, {:error, :invite_revoked}) do
    gone(conn, "INVITE_REVOKED", "Invite revoked", "The host revoked this invite")
  end

  def call(conn, {:error, {:invite_moved, next_code}}) do
    conn
    |> put_status(:gone)
    |> json(%{
      errors: [
        %{
          code: "INVITE_MOVED",
          title: "Invite moved",
          detail: "The host is at a new table; use the next code",
          next_code: next_code
        }
      ]
    })
  end

  def call(conn, {:error, :table_locked}) do
    conn
    |> put_status(:locked)
    |> json(%{
      errors: [
        %{
          code: "TABLE_LOCKED",
          title: "Table locked",
          detail: "The host has locked this table"
        }
      ]
    })
  end

  def call(conn, {:error, :kicked}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: [
        %{
          code: "KICKED",
          title: "Kicked",
          detail: "The host removed you from this table"
        }
      ]
    })
  end

  def call(conn, {:error, :seat_not_kickable}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_NOT_KICKABLE",
          title: "Seat not kickable",
          detail: "Only a seated non-host player can be kicked"
        }
      ]
    })
  end

  # Must stay above the `is_atom(reason)` catch-all, which would answer 422.
  def call(conn, {:error, :room_code_exhausted}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      errors: [
        %{
          code: "ROOM_CODE_EXHAUSTED",
          title: "Room codes exhausted",
          detail: "No free room code could be allocated, please try again shortly"
        }
      ]
    })
  end

  # Room config validation errors (`Room.Config`). Must stay above the
  # `is_atom(reason)` catch-all like every tuple clause here; an unmatched tuple
  # would raise and answer 500. One entry per error in the changeset clause's
  # shape, with the field path (`name`, `settings`, `seats.seat_5`) as the code.
  def call(conn, {:error, {:invalid_room_params, errors}}) when is_list(errors) do
    formatted_errors =
      Enum.map(errors, fn %{field: field, message: message} ->
        %{code: field, title: humanize_field(field), detail: message}
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> Phoenix.Controller.json(ErrorContract.validation(%{errors: formatted_errors}, errors))
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: String.upcase(Atom.to_string(reason)),
          title: reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize(),
          detail: "Operation failed: #{Atom.to_string(reason)}"
        }
      ]
    })
  end

  defp sign_in_action(:password),
    do: %{type: "sign_in", method: "password", endpoint: "/api/v1/auth/login"}

  defp sign_in_action(:apple),
    do: %{type: "sign_in", method: "apple", endpoint: "/api/v1/auth/apple"}

  defp sign_in_action(:facebook),
    do: %{type: "sign_in", method: "facebook", endpoint: "/api/v1/auth/facebook"}

  defp conflict(conn, code, title, detail), do: error(conn, :conflict, code, title, detail)

  defp gone(conn, code, title, detail), do: error(conn, :gone, code, title, detail)

  defp json(conn, payload), do: Phoenix.Controller.json(conn, ErrorContract.rest(payload))

  defp error(conn, status, code, title, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: [%{code: code, title: title, detail: detail}]})
  end

  @doc false
  # Convert field names from underscores to human-readable format. A dotted
  # field path reads as words too: "seats.seat_5" becomes "Seats seat 5".
  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace(["_", "."], " ")
    |> String.capitalize()
  end
end
