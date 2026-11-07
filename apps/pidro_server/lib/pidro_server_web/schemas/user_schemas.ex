defmodule PidroServerWeb.Schemas.UserSchemas do
  @moduledoc """
  OpenAPI schemas for user-related API objects.

  This module defines the OpenAPI 3.0 schemas for all user-related endpoints including:
  - User data objects
  - Authentication request/response objects
  - User statistics responses

  Uses OpenApiSpex.Schema for type safety and documentation.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule FriendSlug do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :string,
      title: "Friend link slug",
      nullable: true,
      description:
        "Optional personal-link slug. Only a new registration or guest upgrade sends the link owner a friend request from the new player, as adding them by hand does; it makes no friendship. Unknown, self, blocked and ignoring owners are silently skipped. A sent request adds data.linked_friend and sends friend_request to the owner."
    })
  end

  defmodule SubmittedAgeBand do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :string,
      title: "Submitted age band",
      enum: ["under_13", "13_17", "18_plus"],
      description: "Self-declared age range; under_13 is refused with AGE_NOT_ELIGIBLE"
    })
  end

  defmodule StoredAgeBand do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :string,
      title: "Stored age band",
      enum: ["unknown", "13_17", "18_plus"]
    })
  end

  defmodule TermsVersion do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :string,
      title: "Terms version",
      minLength: 1,
      maxLength: 32,
      example: "1"
    })
  end

  # ============================================================================
  # User Object Schemas
  # ============================================================================

  defmodule PremiumFields do
    @moduledoc """
    Whether the player is Premium, as the server decides from RevenueCat (PID-125).
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Premium Fields",
      description: "Whether the player is Premium, until when and why",
      properties: %{
        premium: %Schema{
          type: :boolean,
          description: "Whether the player is Premium right now; hide ads when true",
          example: true
        },
        premium_until: %Schema{
          type: :string,
          format: "date-time",
          nullable: true,
          description: "When Premium ends; null when not Premium or when it never ends",
          example: "2027-11-07T10:00:00Z"
        },
        premium_source: %Schema{
          type: :string,
          enum: ["store", "promotional", "classic_honored"],
          nullable: true,
          description:
            "store: a subscription or purchase; promotional: granted by Pidro; classic_honored: Classic premium carried over. Null when not Premium",
          example: "store"
        }
      },
      required: [:premium, :premium_until, :premium_source],
      example: %{
        "premium" => true,
        "premium_until" => "2027-11-07T10:00:00Z",
        "premium_source" => "store"
      }
    })
  end

  defmodule PremiumResponse do
    @moduledoc "The player's Premium fields after a refresh from RevenueCat."

    OpenApiSpex.schema(%{
      type: :object,
      title: "Premium Response",
      properties: %{data: PremiumFields},
      required: [:data]
    })
  end

  defmodule User do
    @moduledoc """
    The User schema represents a user in the system.

    Contains core user information including identification, profile data,
    and account status. Password information is never included in responses
    for security reasons.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User",
      description: "A user account in the Pidro system",
      properties: %{
        id: %Schema{
          type: :string,
          description: "Unique user identifier (UUID)",
          example: "550e8400-e29b-41d4-a716-446655440000"
        },
        username: %Schema{
          type: :string,
          description: "Unique username for login and display",
          minLength: 3,
          example: "john_doe"
        },
        email: %Schema{
          type: :string,
          format: :email,
          nullable: true,
          description: "User's email address, null for passwordless social accounts",
          example: "john@example.com"
        },
        display_name: %Schema{
          type: :string,
          nullable: true,
          minLength: 2,
          maxLength: 20,
          description:
            "Optional display name shown at the table (2-20 graphemes); null when unset",
          example: "Anna"
        },
        share_slug: %Schema{
          type: :string,
          nullable: true,
          pattern: "^[a-z0-9-]{3,30}$",
          description: "Handle of the share link pidro.online/play/<share_slug>; null for guests",
          example: "bengt"
        },
        guest: %Schema{
          type: :boolean,
          description:
            "Whether this is a guest account (upgradable in place with email and password)",
          example: false
        },
        age_band: StoredAgeBand,
        terms_version: %Schema{
          type: :string,
          nullable: true,
          maxLength: 32,
          description: "Accepted terms version, or null when none has been accepted"
        },
        inserted_at: %Schema{
          type: :string,
          format: "date-time",
          description: "ISO 8601 timestamp when the user was created",
          example: "2024-11-02T10:30:00Z"
        },
        updated_at: %Schema{
          type: :string,
          format: "date-time",
          description: "ISO 8601 timestamp when the user was last updated",
          example: "2024-11-02T15:45:30Z"
        },
        premium: PremiumFields.schema().properties.premium,
        premium_until: PremiumFields.schema().properties.premium_until,
        premium_source: PremiumFields.schema().properties.premium_source
      },
      required: [:id, :username, :guest, :age_band, :terms_version, :inserted_at, :updated_at],
      example: %{
        "id" => "550e8400-e29b-41d4-a716-446655440000",
        "username" => "john_doe",
        "email" => "john@example.com",
        "display_name" => nil,
        "guest" => false,
        "age_band" => "unknown",
        "terms_version" => nil,
        "inserted_at" => "2024-11-02T10:30:00Z",
        "updated_at" => "2024-11-02T10:30:00Z"
      }
    })
  end

  defmodule Ads do
    @moduledoc "GET /auth/me: whether the next solo game needs an ad (PID-123)."
    OpenApiSpex.schema(%{
      type: :object,
      title: "Ads",
      description:
        "GET /auth/me only. Not eligible (ads off, not an adult, or premium): every other field is false or 0. A client that shows ads reads /auth/me?ads_aware=true. Before a solo game that needs an ad, show it, POST /me/ads/watched or /me/ads/unavailable, then create the room with ads_aware: true; the game's start uses up the credit.",
      required: [:eligible, :next_game_needs_ad, :games_until_ad, :free_games_left],
      properties: %{
        eligible: %Schema{type: :boolean},
        next_game_needs_ad: %Schema{type: :boolean},
        games_until_ad: %Schema{
          type: :integer,
          minimum: 0,
          description:
            "Solo games that start before the one with an ad; 0 when the next one has it"
        },
        free_games_left: %Schema{
          type: :integer,
          minimum: 0,
          description: "Finished games (Pidro plus Classic) left before ads can start"
        }
      }
    })
  end

  defmodule UserResponse do
    @moduledoc """
    Response containing a single user object.

    Used for endpoints that return user information without authentication tokens,
    such as retrieving the current user's profile.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User Response",
      description: "Response containing user data",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope",
          properties: %{
            user: User,
            seat_invitations: %Schema{
              type: :array,
              description:
                "GET /auth/me: live waiting-room holds for this user, excluding hosts blocked in either direction; disappears on release, decline, seating, game start or room end; the lobby event seat_invitation_gone then carries {code, position, reason}, reason being declined, released, started or closed. Decline with POST /rooms/{code}/seats/{position}/decline. code is the four-character room code for normal join, not an invite secret.",
              items: %Schema{
                type: :object,
                required: [:code, :position, :host_id],
                properties: %{
                  code: %Schema{type: :string},
                  position: %Schema{type: :string, enum: [:north, :east, :south, :west]},
                  host_id: %Schema{type: :string, format: :uuid},
                  host: %Schema{
                    type: :object,
                    required: [:user_id, :display_name, :avatar_url],
                    properties: %{
                      user_id: %Schema{type: :string, format: :uuid},
                      display_name: %Schema{type: :string, nullable: true},
                      avatar_url: %Schema{type: :string, nullable: true}
                    }
                  },
                  rule_set: %Schema{type: :string, enum: [:finnish, :louisiana]},
                  held_since: %Schema{type: :string, format: :"date-time"},
                  join_as: %Schema{
                    type: :string,
                    enum: ["partner", "opponent"],
                    description: "partner when the held seat is across from the host's seat"
                  }
                }
              }
            },
            ads: Ads
          },
          required: [:user]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "user" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "username" => "john_doe",
            "email" => "john@example.com",
            "guest" => false,
            "inserted_at" => "2024-11-02T10:30:00Z",
            "updated_at" => "2024-11-02T10:30:00Z"
          }
        }
      }
    })
  end

  defmodule UserWithTokenResponse do
    @moduledoc """
    Response containing user data and an authentication JWT token.

    Used for successful authentication endpoints (login, register) that need
    to return both the user information and a JWT token for subsequent requests.
    The token should be included in the Authorization header as a Bearer token.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User with Token Response",
      description: "Response containing user data and authentication token",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope",
          properties: %{
            user: User,
            linked_friend: PidroServerWeb.Schemas.FriendSchemas.Player,
            token: %Schema{
              type: :string,
              description:
                "JWT authentication token for subsequent requests. Include as Bearer token in Authorization header",
              example:
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI1NTBlODQwMC1lMjliLTQxZDQtYTcxNi00NDY2NTU0NDAwMDAiLCJpYXQiOjE3MzA1MzgyMDB9.signature"
            }
          },
          required: [:user, :token]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "user" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "username" => "john_doe",
            "email" => "john@example.com",
            "guest" => false,
            "inserted_at" => "2024-11-02T10:30:00Z",
            "updated_at" => "2024-11-02T10:30:00Z"
          },
          "token" =>
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI1NTBlODQwMC1lMjliLTQxZDQtYTcxNi00NDY2NTU0NDAwMDAiLCJpYXQiOjE3MzA1MzgyMDB9.signature"
        }
      }
    })
  end

  # ============================================================================
  # Request Schemas
  # ============================================================================

  defmodule RegisterRequest do
    @moduledoc """
    Request body schema for user registration.

    Clients should provide a user object containing username, email, and password.
    The password must be at least 8 characters long. Username must be at least 3 characters.
    Both username and email must be unique in the system.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Register Request",
      description: "Request body for user registration",
      properties: %{
        friend_slug: FriendSlug,
        age_band: SubmittedAgeBand,
        terms_version: TermsVersion,
        user: %Schema{
          type: :object,
          description: "User registration data",
          properties: %{
            username: %Schema{
              type: :string,
              description: "Unique public username for the account",
              minLength: 3,
              maxLength: 20,
              example: "john_doe"
            },
            email: %Schema{
              type: :string,
              format: :email,
              description: "Email address for the account",
              example: "john@example.com"
            },
            password: %Schema{
              type: :string,
              description: "Account password (minimum 8 characters)",
              minLength: 8,
              maxLength: 255,
              example: "secure_password_123"
            },
            display_name: %Schema{
              type: :string,
              nullable: true,
              minLength: 2,
              maxLength: 20,
              description: "Optional display name (trimmed, 2-20 graphemes)",
              example: "Anna"
            }
          },
          required: [:username, :email, :password]
        }
      },
      required: [:user],
      example: %{
        "user" => %{
          "username" => "john_doe",
          "email" => "john@example.com",
          "password" => "secure_password_123"
        }
      }
    })
  end

  defmodule GuestRequest do
    @moduledoc """
    Request body schema for guest creation.

    A guest may supply a display name; otherwise the server generates one.
    Direct entry also needs a random creation token; invited entry keeps the
    token optional for older clients. A supplied invite is always validated.
    The install id keys a rate-limit bucket and is never logged.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Guest Request",
      description: "Request body for direct or invited guest creation",
      properties: %{
        age_band: SubmittedAgeBand,
        terms_version: TermsVersion,
        display_name: %Schema{
          type: :string,
          nullable: true,
          minLength: 2,
          maxLength: 20,
          description:
            "Optional name shown at the table (2-20 graphemes); omitted or null generates a friendly two-word name, and a supplied name must not look like a connected player's name",
          example: "Anna"
        },
        invite_code: %Schema{
          type: :string,
          description:
            "Optional invite code; when supplied, dashes and lower case are accepted and the invite is always validated",
          example: "7KQ4-M2XB"
        },
        creation_token: %Schema{
          type: :string,
          format: :uuid,
          description:
            "Random UUID required for direct entry. Retry the same token after a lost response; generate a new token after changing the request. Never log it."
        },
        install_id: %Schema{
          type: :string,
          maxLength: 64,
          description: "Opaque per-install id used for rate limiting; never logged",
          example: "b5f6c0d2-3a1e-4f2b-9c8d-1e2f3a4b5c6d"
        },
        platform: %Schema{
          type: :string,
          enum: [:ios, :android, :web],
          description: "Client platform, recorded on the funnel event"
        }
      },
      example: %{
        "creation_token" => "8b597c4a-c208-4cf6-b274-81b29f6751ea",
        "install_id" => "b5f6c0d2-3a1e-4f2b-9c8d-1e2f3a4b5c6d",
        "platform" => "ios"
      }
    })
  end

  defmodule GuestUser do
    @moduledoc "User payload returned for a guest account, whose email is null until upgrade."

    OpenApiSpex.schema(%{
      type: :object,
      title: "Guest User",
      description: "A direct or invited guest account",
      properties: %{
        id: %Schema{
          type: :string,
          description: "Unique user identifier (UUID)",
          example: "550e8400-e29b-41d4-a716-446655440000"
        },
        username: %Schema{
          type: :string,
          description: "Generated unique username",
          minLength: 3,
          example: "guest_7KQ4M2XB"
        },
        email: %Schema{
          type: :string,
          format: :email,
          nullable: true,
          description: "Null until the guest upgrades to a registered account",
          example: nil
        },
        display_name: %Schema{
          type: :string,
          nullable: true,
          minLength: 2,
          maxLength: 20,
          description: "Name shown at the table (2-20 graphemes)",
          example: "Anna"
        },
        guest: %Schema{
          type: :boolean,
          description: "Always true for this response",
          example: true
        },
        age_band: StoredAgeBand,
        terms_version: %Schema{type: :string, nullable: true, maxLength: 32},
        inserted_at: %Schema{
          type: :string,
          format: "date-time",
          description: "ISO 8601 timestamp when the guest was created",
          example: "2026-09-02T10:30:00Z"
        },
        updated_at: %Schema{
          type: :string,
          format: "date-time",
          description: "ISO 8601 timestamp when the guest was last updated",
          example: "2026-09-02T10:30:00Z"
        }
      },
      required: [
        :id,
        :username,
        :email,
        :guest,
        :age_band,
        :terms_version,
        :inserted_at,
        :updated_at
      ],
      example: %{
        "id" => "550e8400-e29b-41d4-a716-446655440000",
        "username" => "guest_7KQ4M2XB",
        "email" => nil,
        "display_name" => "Anna",
        "guest" => true,
        "age_band" => "unknown",
        "terms_version" => nil,
        "inserted_at" => "2026-09-02T10:30:00Z",
        "updated_at" => "2026-09-02T10:30:00Z"
      }
    })
  end

  defmodule GuestResponse do
    @moduledoc """
    Response for a created guest: the user, a token and, for invited entry,
    the invite's state.

    The state tells the client whether to redeem right away (`open`) or show
    the table's situation first (`full`, `locked`, `started`, `closed`, `moved`).
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Guest Response",
      description:
        "Response containing the guest user, a token and, for invited entry, the invite state",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope",
          properties: %{
            user: GuestUser,
            token: %Schema{
              type: :string,
              description:
                "Signed Phoenix authentication token for subsequent Bearer-authenticated requests"
            },
            state: PidroServerWeb.Schemas.InviteSchemas.State
          },
          required: [:user, :token]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "user" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "username" => "guest_7KQ4M2XB",
            "email" => nil,
            "display_name" => "Anna",
            "guest" => true,
            "inserted_at" => "2026-09-02T10:30:00Z",
            "updated_at" => "2026-09-02T10:30:00Z"
          },
          "token" => "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.signature",
          "state" => "open"
        }
      }
    })
  end

  defmodule UpgradeRequest do
    @moduledoc """
    Request body schema for upgrading a guest into a registered account (R13).

    Email and password are required; a username is optional and replaces the
    generated guest username. Fields may also be nested under `user`.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Upgrade Request",
      description: "Request body for upgrading the calling guest in place",
      properties: %{
        friend_slug: FriendSlug,
        age_band: SubmittedAgeBand,
        terms_version: TermsVersion,
        email: %Schema{
          type: :string,
          format: :email,
          description: "Email address for the account (unique, case-insensitive)",
          example: "anna@example.com"
        },
        password: %Schema{
          type: :string,
          description: "Account password (minimum 8 characters)",
          minLength: 8,
          maxLength: 255,
          example: "secure_password_123"
        },
        username: %Schema{
          type: :string,
          description: "Optional public username replacing the generated guest username",
          minLength: 3,
          maxLength: 20,
          example: "anna"
        }
      },
      required: [:email, :password],
      example: %{
        "email" => "anna@example.com",
        "password" => "secure_password_123"
      }
    })
  end

  defmodule LoginRequest do
    @moduledoc """
    Request body schema for user login.

    Clients should provide an identifier (username or email address) in the
    `username` field and a password. Both fields are required. On successful
    authentication, the server returns the user data and a JWT token.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Login Request",
      description: "Request body for user login/authentication",
      properties: %{
        age_band: SubmittedAgeBand,
        terms_version: TermsVersion,
        username: %Schema{
          type: :string,
          description:
            "Username or email address of the account; an identifier containing `@` is matched against the email",
          minLength: 3,
          example: "john_doe"
        },
        password: %Schema{
          type: :string,
          description: "Password for the account",
          minLength: 1,
          example: "secure_password_123"
        }
      },
      required: [:username, :password],
      example: %{
        "username" => "john_doe",
        "password" => "secure_password_123"
      }
    })
  end

  defmodule AgeRequest do
    @moduledoc false

    OpenApiSpex.schema(%{
      type: :object,
      title: "Age and terms declaration request",
      properties: %{
        age_band: SubmittedAgeBand,
        terms_version: TermsVersion
      },
      required: [:age_band],
      example: %{"age_band" => "18_plus", "terms_version" => "1"}
    })
  end

  # ============================================================================
  # Statistics Schemas
  # ============================================================================

  defmodule UserStatsResponse do
    @moduledoc """
    Response containing user game statistics.

    Aggregates game-related metrics for a user including total games played,
    win/loss records, abandonment metrics, time spent playing, and average bid amounts.
    All numeric fields are calculated from the user's game history.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User Stats Response",
      description: "Response containing aggregated user game statistics",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope containing user statistics",
          properties: %{
            games_played: %Schema{
              type: :integer,
              description: "Total number of games the user has participated in",
              minimum: 0,
              example: 42
            },
            wins: %Schema{
              type: :integer,
              description: "Total number of games won by the user",
              minimum: 0,
              example: 25
            },
            losses: %Schema{
              type: :integer,
              description: "Total number of games lost by the user",
              minimum: 0,
              example: 17
            },
            win_rate: %Schema{
              type: :number,
              format: :double,
              description: "Win rate as a decimal (0.0 to 1.0, or 0 if no games played)",
              minimum: 0.0,
              maximum: 1.0,
              example: 0.595
            },
            total_duration_seconds: %Schema{
              type: :integer,
              description: "Total time spent playing in seconds",
              minimum: 0,
              example: 12_600
            },
            average_bid: %Schema{
              type: :number,
              format: :double,
              description: "Average bid amount across all games",
              minimum: 0.0,
              example: 10.5
            },
            games_abandoned: %Schema{
              type: :integer,
              description: "Total number of games abandoned after the reconnect grace period",
              minimum: 0,
              example: 3
            },
            abandonment_rate: %Schema{
              type: :number,
              format: :double,
              description: "Abandonment rate as a decimal (0.0 to 1.0, or 0 if no games played)",
              minimum: 0.0,
              example: 0.071
            },
            last_abandoned_at: %Schema{
              type: :string,
              format: "date-time",
              nullable: true,
              description: "Most recent time the user abandoned a game after grace expired",
              example: "2026-03-11T19:30:00Z"
            }
          },
          required: [
            :games_played,
            :wins,
            :losses,
            :win_rate,
            :total_duration_seconds,
            :average_bid,
            :games_abandoned,
            :abandonment_rate,
            :last_abandoned_at
          ]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "games_played" => 42,
          "wins" => 25,
          "losses" => 17,
          "win_rate" => 0.595,
          "total_duration_seconds" => 12_600,
          "average_bid" => 10.5,
          "games_abandoned" => 3,
          "abandonment_rate" => 0.071,
          "last_abandoned_at" => "2026-03-11T19:30:00Z"
        }
      }
    })
  end

  # ============================================================================
  # Error Response Schemas
  # ============================================================================

  defmodule ErrorResponse do
    @moduledoc """
    Standard error response schema used across all API endpoints.

    Errors are returned in a consistent format with error codes, titles, and details.
    Multiple errors can be returned in a single response (e.g., validation errors).
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Error Response",
      description: "Standard error response format",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array of errors",
          items: %Schema{
            type: :object,
            properties: %{
              code: %Schema{
                type: :string,
                description: "Error code (field name for validation errors, or error type)",
                example: "username"
              },
              title: %Schema{
                type: :string,
                description: "Human-readable error title",
                example: "Username"
              },
              detail: %Schema{
                type: :string,
                description: "Detailed error message",
                example: "has already been taken"
              }
            },
            required: [:code, :title, :detail]
          }
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "username",
            "title" => "Username",
            "detail" => "has already been taken"
          }
        ]
      }
    })
  end

  defmodule UnauthorizedError do
    @moduledoc """
    Error response for unauthorized access (401).

    Returned when authentication is required but not provided, or when
    the provided token is invalid or expired.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Unauthorized Error",
      description: "Error response for unauthorized access",
      properties: %{
        errors: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              code: %Schema{
                type: :string,
                example: "UNAUTHORIZED"
              },
              title: %Schema{
                type: :string,
                example: "Unauthorized"
              },
              detail: %Schema{
                type: :string,
                example: "Authentication required"
              }
            }
          }
        }
      },
      example: %{
        "errors" => [
          %{
            "code" => "UNAUTHORIZED",
            "title" => "Unauthorized",
            "detail" => "Authentication required"
          }
        ]
      }
    })
  end
end
