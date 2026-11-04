defmodule PidroServerWeb.Schemas.FriendSchemas do
  @moduledoc "Wire contract for friends and player discovery (PID-223)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule Player do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "FriendPlayer",
      type: :object,
      required: [:user_id, :display_name, :avatar_url, :level, :prestige, :presence],
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string, nullable: true},
        avatar_url: %Schema{type: :string, nullable: true},
        level: %Schema{type: :integer, minimum: 1, description: "All-time level, 1 to 100"},
        prestige: %Schema{
          type: :integer,
          minimum: 0,
          description: "Legend stars, one per 500,000 XP past level 100 (0 below that)"
        },
        presence: %Schema{type: :string, enum: ["online", "at_table", "offline"]},
        table_company: %Schema{
          type: :string,
          enum: ["bots", "people"],
          description:
            "Only when at_table: bots alone in a started game, otherwise people (any table that has not started)"
        },
        table_open_seats: %Schema{
          type: :integer,
          minimum: 0,
          description: "Only when at_table: publicly open seats, excluding holds"
        },
        table_hand: %Schema{
          type: :integer,
          nullable: true,
          description: "Only when at_table: current hand while playing, otherwise null"
        },
        played_together_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "For mutual friends: latest completed game shared with the viewer, or null"
        },
        requested_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "For incoming requests: when the sender added the viewer"
        },
        join_as: %Schema{
          type: :string,
          enum: ["partner", "opponent"],
          nullable: true,
          description:
            "Mutual friends only: what POST /friends/:user_id/join would make you at their table; null when they are not at one or there is no seat for you"
        }
      }
    })
  end

  defmodule RequestedPlayer do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "RequestedFriendPlayer",
      type: :object,
      required: [
        :user_id,
        :display_name,
        :avatar_url,
        :level,
        :prestige,
        :presence,
        :requested_at
      ],
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string, nullable: true},
        avatar_url: %Schema{type: :string, nullable: true},
        level: %Schema{type: :integer, minimum: 1, description: "All-time level, 1 to 100"},
        prestige: %Schema{
          type: :integer,
          minimum: 0,
          description: "Legend stars, one per 500,000 XP past level 100 (0 below that)"
        },
        presence: %Schema{type: :string, enum: ["online", "at_table", "offline"]},
        table_company: %Schema{
          type: :string,
          enum: ["bots", "people"],
          description:
            "Only when at_table: bots alone in a started game, otherwise people (any table that has not started)"
        },
        table_open_seats: %Schema{
          type: :integer,
          minimum: 0,
          description: "Only when at_table: publicly open seats, excluding holds"
        },
        table_hand: %Schema{
          type: :integer,
          nullable: true,
          description: "Only when at_table: current hand while playing, otherwise null"
        },
        requested_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the viewer sent this request"
        }
      }
    })
  end

  defmodule DiscoveryPlayer do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "DiscoveryPlayer",
      type: :object,
      required: [:user_id, :display_name, :avatar_url, :level, :prestige, :presence, :relation],
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string, nullable: true},
        avatar_url: %Schema{type: :string, nullable: true},
        level: %Schema{type: :integer, minimum: 1, description: "All-time level, 1 to 100"},
        prestige: %Schema{
          type: :integer,
          minimum: 0,
          description: "Legend stars, one per 500,000 XP past level 100 (0 below that)"
        },
        presence: %Schema{type: :string, enum: ["online", "at_table", "offline"]},
        table_company: %Schema{
          type: :string,
          enum: ["bots", "people"],
          description:
            "Only when at_table: bots alone in a started game, otherwise people (any table that has not started)"
        },
        table_open_seats: %Schema{
          type: :integer,
          minimum: 0,
          description: "Only when at_table: publicly open seats, excluding holds"
        },
        table_hand: %Schema{
          type: :integer,
          nullable: true,
          description: "Only when at_table: current hand while playing, otherwise null"
        },
        played_together_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Recent only: newest shared completion in the viewer's last twenty games"
        },
        relation: %Schema{type: :string, enum: ["none", "friend", "added_you", "added"]}
      }
    })
  end

  defmodule ListResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "FriendsResponse",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [:friends, :added_you, :requested, :requests_waiting, :waiting_for_you],
          properties: %{
            friends: %Schema{type: :array, items: Player},
            added_you: %Schema{
              type: :array,
              items: Player,
              description: "Incoming requests you have not ignored, newest first."
            },
            requested: %Schema{
              type: :array,
              items: RequestedPlayer,
              description: "Requests you sent with none back, newest first."
            },
            requests_waiting: %Schema{
              type: :integer,
              minimum: 0,
              description: "Count of added_you."
            },
            waiting_for_you: %Schema{
              type: :integer,
              minimum: 0,
              description:
                "Friend requests waiting for your answer plus your live seat invitations, for the badge."
            },
            classic: %Schema{
              type: :object,
              description: "Claimed accounts only: outgoing Classic friends not yet claimed.",
              required: [:not_here],
              properties: %{not_here: %Schema{type: :integer, minimum: 0}}
            }
          }
        }
      }
    })
  end

  defmodule UsersResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "FriendUsersResponse",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [:users],
          properties: %{users: %Schema{type: :array, items: DiscoveryPlayer, maxItems: 10}}
        }
      }
    })
  end

  defmodule Error do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "FriendError",
      type: :object,
      required: [:error],
      properties: %{
        error_code: %Schema{
          type: :string,
          description: "Stable localization key; the legacy error field is unchanged",
          enum: ["account_required", "cannot_friend_self", "user_not_found", "query_too_short"]
        },
        error_params: %Schema{type: :object, additionalProperties: false},
        error: %Schema{
          type: :string,
          enum: ["ACCOUNT_REQUIRED", "CANNOT_FRIEND_SELF", "USER_NOT_FOUND", "QUERY_TOO_SHORT"]
        }
      }
    })
  end
end
