defmodule PidroServerWeb.Schemas.RoomSchemas do
  @moduledoc """
  OpenAPI schema definitions for Room-related API objects.

  This module defines the OpenAPI 3.0 schemas used in room-related endpoints,
  including game state, player information, cards, bids, tricks, and plays.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PidroServer.Games.Room.Config

  # ==================== Room Schemas ====================

  defmodule HeldFor do
    @moduledoc "The public profile of the user a vacant seat waits for."
    OpenApiSpex.schema(%{
      title: "HeldFor",
      type: :object,
      required: [:user_id, :display_name, :avatar_url],
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string, nullable: true},
        avatar_url: %Schema{type: :string, nullable: true}
      }
    })
  end

  defmodule Seat do
    @moduledoc "Schema for a Seat at the table."

    OpenApiSpex.schema(%{
      title: "Seat",
      description: "A seat at the table with occupant and connection state",
      type: :object,
      properties: %{
        held_for: HeldFor,
        vacated_by: %Schema{
          type: :string,
          description: "Departed player's display name, only on a vacant substitute seat"
        },
        min_games: %Schema{
          type: :integer,
          enum: [0, 100, 1000],
          description: "Games required for an open seat; zero on occupied and bot seats"
        },
        password: %Schema{
          type: :boolean,
          description:
            "Whether sitting in this open seat needs the table's seat password; false on occupied, bot and held seats"
        },
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Table position"
        },
        occupant_type: %Schema{
          type: :string,
          enum: [:human, :bot, :vacant],
          description: "Type of occupant"
        },
        user_id: %Schema{
          type: :string,
          nullable: true,
          description: "User ID of human occupant"
        },
        is_bot: %Schema{
          type: :boolean,
          description: "Whether a bot plays this seat, including a substitute bot"
        },
        bot_persona: %Schema{
          type: :string,
          enum: ["marcel", "antti", "jocke"],
          nullable: true,
          description:
            "Who a real bot seat is named after; null for humans, vacant seats and substitute bots"
        },
        username: %Schema{
          type: :string,
          nullable: true,
          description:
            "Occupant's username; the persona's name (\"Marcel\", \"Antti\", \"Jocke\") for a bot with a persona, \"Bot\" for other bots, null when the id resolves to nobody"
        },
        display_name: %Schema{
          type: :string,
          nullable: true,
          description:
            "Occupant's display name; the persona's name for a bot with a persona, \"Bot\" for other bots, null when unset or when the id resolves to nobody"
        },
        level: %Schema{
          type: :integer,
          nullable: true,
          minimum: 1,
          description:
            "Occupant's all-time level; null for bots, vacant seats and ids that resolve to nobody"
        },
        pin: %Schema{
          type: :string,
          enum: ["classic"],
          nullable: true,
          description: "\"classic\" for a claimed Classic account, else null"
        },
        status: %Schema{
          type: :string,
          enum: [:connected, :reconnecting, :grace, :bot_substitute, :free],
          nullable: true,
          description: "Connection status; a vacant friend hold is `free` with `held_for`"
        },
        is_owner: %Schema{
          type: :boolean,
          description: "Whether this seat belongs to the room owner"
        },
        substitute: %Schema{
          type: :boolean,
          description: "Whether this human joined as a substitute"
        },
        disconnected_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the player disconnected"
        },
        grace_expires_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the grace period expires"
        },
        has_reservation: %Schema{
          type: :boolean,
          description: "Whether the original player can still reclaim this seat"
        },
        joined_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the player joined"
        }
      },
      required: [:position, :occupant_type, :is_owner, :substitute, :has_reservation]
    })
  end

  defmodule RoomConfig do
    @moduledoc "Schema for a room's config: how the table was set up when it was created."

    OpenApiSpex.schema(%{
      title: "RoomConfig",
      description: """
      How the room was set up when it was created. Set once at creation and
      unchanged for the life of the room. The seat plan sent at creation is not
      part of it: seats change during play, so read `seats` for the table as it stands.
      """,
      type: :object,
      properties: %{
        rule_set: %Schema{type: :string, enum: Config.rule_sets(), default: "finnish"},
        name: %Schema{
          type: :string,
          nullable: true,
          maxLength: Config.max_name_length(),
          description: "Room name, or null when none was given",
          example: "Fun Game Night"
        },
        bot_difficulty: %Schema{
          type: :string,
          enum: Config.difficulties(),
          deprecated: true,
          description:
            "Deprecated compatibility field, echoing the legacy request. All values use the same rulebook",
          example: "basic"
        },
        solo: %Schema{
          type: :boolean,
          description:
            "Whether the room was created with all three other seats as bots. Solo rooms are hidden from the lobby",
          example: false
        }
      },
      required: [:name, :bot_difficulty, :rule_set, :solo],
      example: %{
        "name" => "Fun Game Night",
        "bot_difficulty" => "basic",
        "rule_set" => "finnish",
        "solo" => false
      }
    })
  end

  defmodule SeatPlanEntry do
    @moduledoc "An initial bot, held or open seat, optionally requiring experience or a password."
    OpenApiSpex.schema(%{
      title: "SeatPlanEntry",
      oneOf: [
        %Schema{type: :string, enum: Config.seat_values()},
        %Schema{
          type: :object,
          additionalProperties: false,
          required: [:type, :min_games],
          properties: %{
            type: %Schema{type: :string, enum: ["open"]},
            min_games: %Schema{type: :integer, enum: [0, 100, 1000]},
            password: %Schema{
              type: :boolean,
              default: false,
              description:
                "Sitting here needs the table's seat password, which the server draws and shows only to the host"
            }
          }
        },
        %Schema{
          type: :object,
          additionalProperties: false,
          required: [:type, :user_id],
          properties: %{
            type: %Schema{type: :string, enum: ["held"]},
            user_id: %Schema{type: :string, format: :uuid}
          }
        }
      ]
    })
  end

  defmodule SeatRequiresGames do
    @moduledoc "The experience gate's HTTP 403 response."
    OpenApiSpex.schema(%{
      title: "SeatRequiresGames",
      type: :object,
      required: [:error, :min_games, :games_played],
      properties: %{
        error: %Schema{type: :string, enum: ["SEAT_REQUIRES_GAMES"]},
        min_games: %Schema{type: :integer, enum: [100, 1000]},
        games_played: %Schema{type: :integer, minimum: 0}
      }
    })
  end

  defmodule RoomCreateRequest do
    @moduledoc "Schema for the create-room request body."

    OpenApiSpex.schema(%{
      title: "RoomCreateRequest",
      description: """
      The create-room request body: a flat object. Every field is optional, and an
      empty body creates an unnamed room with three open seats and `basic` bots.
      Any other key is rejected with a 422 that names it.

      The top-level properties must match `PidroServer.Games.Room.Config.accepted_fields/0`;
      a spec test fails when the two drift apart. The enums and the name cap are
      read from that module, so they cannot.
      """,
      type: :object,
      additionalProperties: false,
      properties: %{
        rule_set: %Schema{type: :string, enum: Config.rule_sets(), default: "finnish"},
        name: %Schema{
          type: :string,
          maxLength: Config.max_name_length(),
          description:
            "Room name. Trimmed; at most #{Config.max_name_length()} characters after trimming. Missing or blank means no name",
          example: "Fun Game Night"
        },
        seats: %Schema{
          type: :object,
          additionalProperties: false,
          description: """
          Seat plan for the three seats other than the host's: `seat_2` is east,
          `seat_3` is south, `seat_4` is west. A missing seat is `open`. When all
          three are `ai` the room is a solo room.
          """,
          properties: %{
            seat_2: SeatPlanEntry,
            seat_3: SeatPlanEntry,
            seat_4: SeatPlanEntry
          }
        },
        bot_difficulty: %Schema{
          type: :string,
          enum: Config.difficulties(),
          default: "basic",
          deprecated: true,
          description: "Deprecated; omit this field. All accepted values use the same rulebook"
        }
      },
      example: %{
        "name" => "Fun Game Night",
        "seats" => %{"seat_2" => "ai", "seat_3" => "open", "seat_4" => "ai"},
        "bot_difficulty" => "smart"
      }
    })
  end

  defmodule GameProgress do
    @moduledoc "Public progress for a playing room."

    OpenApiSpex.schema(%{
      title: "GameProgress",
      description: "Present only while the room is playing; omitted otherwise",
      type: :object,
      required: [:hand, :scores],
      properties: %{
        hand: %Schema{type: :integer, minimum: 1},
        scores: %Schema{
          type: :object,
          description: "Cumulative team scores; may be negative",
          required: [:north_south, :east_west],
          properties: %{
            north_south: %Schema{type: :integer},
            east_west: %Schema{type: :integer}
          }
        }
      },
      example: %{hand: 4, scores: %{north_south: 34, east_west: 21}}
    })
  end

  defmodule Room do
    @moduledoc "Schema for a Room object representing a game room."

    OpenApiSpex.schema(%{
      title: "Room",
      description: "A game room for playing Pidro with up to 4 players",
      type: :object,
      properties: %{
        game: GameProgress,
        code: %Schema{
          type: :string,
          description: "Unique 4-character room code",
          example: "A1B2",
          minLength: 4,
          maxLength: 4
        },
        host_id: %Schema{
          type: :string,
          nullable: true,
          description: "User ID of the current room owner, or null when no human owner remains",
          example: "user123"
        },
        positions: %Schema{
          type: :object,
          description: "Map of position names to the seated player's ID, or null when unoccupied",
          properties: %{
            north: %Schema{type: :string, nullable: true},
            east: %Schema{type: :string, nullable: true},
            south: %Schema{type: :string, nullable: true},
            west: %Schema{type: :string, nullable: true}
          },
          example: %{"north" => "user123", "east" => nil, "south" => "user456", "west" => nil}
        },
        available_positions: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: [:north, :east, :south, :west]},
          description:
            "Positions a player can claim now. Empty when the table is locked or the room is over",
          example: ["east", "west"]
        },
        player_count: %Schema{
          type: :integer,
          description: "Number of occupied seats, bots included",
          example: 2
        },
        player_ids: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Legacy: IDs of seated players in north, east, south, west order",
          example: ["user123", "user456"]
        },
        spectator_ids: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "IDs of users spectating the room",
          example: []
        },
        status: %Schema{
          type: :string,
          enum: [:waiting, :ready, :playing, :finished],
          description: "Current status of the room",
          example: "waiting"
        },
        locked: %Schema{
          type: :boolean,
          description:
            "Whether the host has locked the table against joins and invite redemptions",
          example: false
        },
        max_players: %Schema{
          type: :integer,
          description: "Maximum number of players allowed",
          example: 4
        },
        max_spectators: %Schema{
          type: :integer,
          description: "Maximum number of spectators allowed",
          example: 10
        },
        config: RoomConfig,
        seat_password: %Schema{
          type: :string,
          pattern: "^[0-9]{4}$",
          description:
            "The table's four-digit seat password. Only in the host's own responses, and only once a seat has needed one",
          example: "4821"
        },
        seats: %Schema{
          type: :object,
          additionalProperties: Seat,
          description: "Map of position names to seat objects"
        },
        created_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "ISO8601 timestamp when the room was created",
          example: "2024-11-02T10:30:00Z"
        }
      },
      required: [
        :code,
        :host_id,
        :positions,
        :available_positions,
        :player_count,
        :player_ids,
        :spectator_ids,
        :status,
        :locked,
        :max_players,
        :max_spectators,
        :created_at,
        :config,
        :seats
      ],
      example: %{
        "code" => "A1B2",
        "host_id" => "user123",
        "positions" => %{
          "north" => "user123",
          "east" => nil,
          "south" => "user456",
          "west" => nil
        },
        "available_positions" => ["east", "west"],
        "player_count" => 2,
        "player_ids" => ["user123", "user456"],
        "spectator_ids" => [],
        "status" => "waiting",
        "locked" => false,
        "max_players" => 4,
        "max_spectators" => 10,
        "config" => %{
          "name" => "Fun Game Night",
          "bot_difficulty" => "basic",
          "rule_set" => "finnish",
          "solo" => false
        },
        "seats" => %{
          "north" => %{
            "position" => "north",
            "occupant_type" => "human",
            "user_id" => "user123",
            "username" => "marcel",
            "display_name" => "Marcel",
            "status" => "connected",
            "is_owner" => true,
            "substitute" => false,
            "has_reservation" => false,
            "joined_at" => "2024-11-02T10:30:00Z"
          },
          "south" => %{
            "position" => "south",
            "occupant_type" => "human",
            "user_id" => "user456",
            "status" => "connected",
            "is_owner" => false,
            "substitute" => false,
            "has_reservation" => false,
            "joined_at" => "2024-11-02T10:31:00Z"
          },
          "east" => %{
            "position" => "east",
            "occupant_type" => "vacant",
            "user_id" => nil,
            "is_owner" => false,
            "substitute" => false,
            "has_reservation" => false
          },
          "west" => %{
            "position" => "west",
            "occupant_type" => "vacant",
            "user_id" => nil,
            "is_owner" => false,
            "substitute" => false,
            "has_reservation" => false
          }
        },
        "created_at" => "2024-11-02T10:30:00Z"
      }
    })
  end

  defmodule RoomResponse do
    @moduledoc "Schema for a single room response."

    OpenApiSpex.schema(%{
      title: "RoomResponse",
      description: "Response containing a single room object",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            room: Room
          },
          required: [:room]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "room" => %{
            "code" => "A1B2",
            "host_id" => "user123",
            "positions" => %{
              "north" => "user123",
              "east" => nil,
              "south" => nil,
              "west" => nil
            },
            "available_positions" => ["east", "south", "west"],
            "player_count" => 1,
            "player_ids" => ["user123"],
            "spectator_ids" => [],
            "status" => "waiting",
            "locked" => false,
            "max_players" => 4,
            "max_spectators" => 10,
            "config" => %{
              "name" => "Fun Game Night",
              "bot_difficulty" => "basic",
              "rule_set" => "finnish",
              "solo" => false
            },
            "seats" => %{
              "north" => %{
                "position" => "north",
                "occupant_type" => "human",
                "user_id" => "user123",
                "is_owner" => true,
                "substitute" => false,
                "has_reservation" => false
              }
            },
            "created_at" => "2024-11-02T10:30:00Z"
          }
        }
      }
    })
  end

  defmodule RoomsResponse do
    @moduledoc "Schema for a list of rooms response."

    OpenApiSpex.schema(%{
      title: "RoomsResponse",
      description: "Response containing a list of room objects",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            rooms: %Schema{
              type: :array,
              items: Room,
              description: "List of room objects"
            }
          },
          required: [:rooms]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "rooms" => [
            %{
              "code" => "A1B2",
              "host_id" => "user123",
              "positions" => %{
                "north" => "user123",
                "east" => nil,
                "south" => "user456",
                "west" => nil
              },
              "available_positions" => ["east", "west"],
              "player_count" => 2,
              "player_ids" => ["user123", "user456"],
              "spectator_ids" => [],
              "status" => "waiting",
              "locked" => false,
              "max_players" => 4,
              "max_spectators" => 10,
              "config" => %{
                "name" => "Fun Game Night",
                "bot_difficulty" => "basic",
                "rule_set" => "finnish",
                "solo" => false
              },
              "seats" => %{},
              "created_at" => "2024-11-02T10:30:00Z"
            },
            %{
              "code" => "X9Z8",
              "host_id" => "user789",
              "positions" => %{
                "north" => "user789",
                "east" => nil,
                "south" => nil,
                "west" => nil
              },
              "available_positions" => ["east", "south", "west"],
              "player_count" => 1,
              "player_ids" => ["user789"],
              "spectator_ids" => [],
              "status" => "waiting",
              "locked" => false,
              "max_players" => 4,
              "max_spectators" => 10,
              "config" => %{
                "name" => nil,
                "bot_difficulty" => "basic",
                "rule_set" => "finnish",
                "solo" => false
              },
              "seats" => %{},
              "created_at" => "2024-11-02T10:35:00Z"
            }
          ]
        }
      }
    })
  end

  defmodule RoomCreatedResponse do
    @moduledoc "Schema for room creation response including the room code."

    OpenApiSpex.schema(%{
      title: "RoomCreatedResponse",
      description:
        "Response when a room is created, including the room and a convenience code field",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            room: Room,
            code: %Schema{
              type: :string,
              description: "Convenience copy of the room code",
              example: "A1B2"
            }
          },
          required: [:room, :code]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "room" => %{
            "code" => "A1B2",
            "host_id" => "user123",
            "positions" => %{
              "north" => "user123",
              "east" => nil,
              "south" => nil,
              "west" => nil
            },
            "available_positions" => ["east", "south", "west"],
            "player_count" => 1,
            "player_ids" => ["user123"],
            "spectator_ids" => [],
            "status" => "waiting",
            "locked" => false,
            "max_players" => 4,
            "max_spectators" => 10,
            "config" => %{
              "name" => "Fun Game Night",
              "bot_difficulty" => "basic",
              "rule_set" => "finnish",
              "solo" => false
            },
            "seats" => %{
              "north" => %{
                "position" => "north",
                "occupant_type" => "human",
                "user_id" => "user123",
                "is_owner" => true,
                "substitute" => false,
                "has_reservation" => false
              }
            },
            "created_at" => "2024-11-02T10:30:00Z"
          },
          "code" => "A1B2"
        }
      }
    })
  end

  # ==================== Game State Schemas ====================

  defmodule Card do
    @moduledoc "Schema for a Card object representing a playing card."

    OpenApiSpex.schema(%{
      title: "Card",
      description:
        "A playing card with rank and suit. Rank values: 2-10 (numeric), 11 (Jack), 12 (Queen), 13 (King), 14 (Ace). Suit values: hearts, diamonds, clubs, spades",
      type: :object,
      properties: %{
        rank: %Schema{
          oneOf: [
            %Schema{type: :integer, minimum: 2, maximum: 10, description: "Numeric rank 2-10"},
            %Schema{type: :integer, enum: [11, 12, 13, 14], description: "Face cards and Ace"}
          ],
          description: "Card rank (2-14, where 11=Jack, 12=Queen, 13=King, 14=Ace)",
          example: 14
        },
        suit: %Schema{
          type: :string,
          enum: [:hearts, :diamonds, :clubs, :spades],
          description: "Card suit",
          example: :hearts
        }
      },
      required: [:rank, :suit],
      example: %{
        "rank" => 14,
        "suit" => "hearts"
      }
    })
  end

  defmodule Bid do
    @moduledoc "Schema for a Bid object representing a player's bid."

    OpenApiSpex.schema(%{
      title: "Bid",
      description: "A bid made by a player during the bidding phase",
      type: :object,
      properties: %{
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Player position",
          example: :north
        },
        amount: %Schema{
          oneOf: [
            %Schema{type: :integer, minimum: 6, maximum: 14, description: "Numeric bid"},
            %Schema{type: :string, enum: ["pass"], description: "Pass indicator"}
          ],
          description: "Bid amount (Finnish 6-14, Louisiana 7-14) or 'pass' to pass",
          example: 8
        }
      },
      required: [:position, :amount],
      example: %{
        "position" => "north",
        "amount" => 8
      }
    })
  end

  defmodule Play do
    @moduledoc "Schema for a Play object representing a card played in a trick."

    OpenApiSpex.schema(%{
      title: "Play",
      description: "A card played by a player in a trick",
      type: :object,
      properties: %{
        player: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Position of the player who played the card",
          example: :north
        },
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Legacy alias for player (backward compatibility)",
          example: :north
        },
        card: Card
      },
      required: [:player, :position, :card],
      example: %{
        "player" => "north",
        "position" => "north",
        "card" => %{
          "rank" => 14,
          "suit" => "hearts"
        }
      }
    })
  end

  defmodule Trick do
    @moduledoc "Schema for a Trick object representing a completed trick."

    OpenApiSpex.schema(%{
      title: "Trick",
      description: "A completed trick including legacy (`plays`) and frontend (`cards`) arrays",
      type: :object,
      properties: %{
        number: %Schema{
          type: :integer,
          description: "Sequential trick number (1-13)",
          minimum: 1,
          maximum: 13,
          example: 1
        },
        leader: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Position of the player who led the trick",
          example: :north
        },
        plays: %Schema{
          type: :array,
          items: Play,
          description: "Legacy list of cards played in order",
          example: [
            %{
              "player" => "north",
              "position" => "north",
              "card" => %{"rank" => 14, "suit" => "hearts"}
            },
            %{
              "player" => "east",
              "position" => "east",
              "card" => %{"rank" => 13, "suit" => "hearts"}
            }
          ]
        },
        cards: %Schema{
          type: :array,
          items: Play,
          description: "Frontend-oriented list of cards played in order",
          example: [
            %{
              "player" => "north",
              "position" => "north",
              "card" => %{"rank" => 14, "suit" => "hearts"}
            },
            %{
              "player" => "east",
              "position" => "east",
              "card" => %{"rank" => 13, "suit" => "hearts"}
            }
          ]
        },
        winner: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Position of the player who won the trick",
          example: :north,
          nullable: true
        },
        points: %Schema{
          type: :integer,
          description: "Winner's share of trick points, excluding the 2 of trump",
          minimum: 0,
          example: 1
        },
        two_of_trump: %Schema{
          type: :object,
          nullable: true,
          description: "The player who keeps the 2-of-trump point, or null if not played",
          properties: %{
            position: %Schema{type: :string, enum: [:north, :south, :east, :west]},
            points: %Schema{type: :integer, enum: [1]}
          },
          required: [:position, :points]
        }
      },
      required: [:plays, :cards, :points],
      example: %{
        "number" => 1,
        "leader" => "north",
        "plays" => [
          %{
            "player" => "north",
            "position" => "north",
            "card" => %{"rank" => 14, "suit" => "hearts"}
          },
          %{
            "player" => "east",
            "position" => "east",
            "card" => %{"rank" => 13, "suit" => "hearts"}
          }
        ],
        "cards" => [
          %{
            "player" => "north",
            "position" => "north",
            "card" => %{"rank" => 14, "suit" => "hearts"}
          },
          %{
            "player" => "east",
            "position" => "east",
            "card" => %{"rank" => 13, "suit" => "hearts"}
          }
        ],
        "winner" => "north",
        "points" => 1,
        "two_of_trump" => nil
      }
    })
  end

  defmodule PointCard do
    @moduledoc "A card that scored in a hand, with the seat and team that took its points."

    OpenApiSpex.schema(%{
      title: "PointCard",
      type: :object,
      properties: %{
        card: Card,
        points: %Schema{type: :integer, minimum: 1, maximum: 5},
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "The trick winner, or the player of the 2 of trump, who keeps it"
        },
        team: %Schema{type: :string, enum: [:north_south, :east_west]}
      },
      required: [:card, :points, :position, :team],
      example: %{
        "card" => %{"rank" => 5, "suit" => "hearts"},
        "points" => 5,
        "position" => "east",
        "team" => "east_west"
      }
    })
  end

  defmodule HandSummary do
    @moduledoc "A scored hand as kept in `hand_history`: `last_hand` without bids and tricks."

    @team_scores %Schema{
      type: :object,
      properties: %{
        north_south: %Schema{type: :integer},
        east_west: %Schema{type: :integer}
      },
      required: [:north_south, :east_west]
    }

    OpenApiSpex.schema(%{
      title: "HandSummary",
      type: :object,
      properties: %{
        hand_number: %Schema{type: :integer, minimum: 1},
        bidding_team: %Schema{type: :string, enum: [:north_south, :east_west]},
        bidder: %Schema{type: :string, enum: [:north, :south, :east, :west]},
        bid: %Schema{type: :integer, minimum: 6, maximum: 14},
        captured: %Schema{
          type: :object,
          description: "Final captured points, including the 2 of trump for its player's team",
          properties: %{
            north_south: %Schema{type: :integer, minimum: 0},
            east_west: %Schema{type: :integer, minimum: 0}
          },
          required: [:north_south, :east_west]
        },
        made: %Schema{type: :boolean, description: "Whether the bidding team made its bid"},
        delta: %Schema{
          @team_scores
          | description: "Score changes actually applied; may be negative"
        },
        scores: %Schema{@team_scores | description: "Cumulative scores after this hand"},
        trump: %Schema{
          type: :string,
          enum: [:hearts, :diamonds, :clubs, :spades],
          nullable: true,
          description: "The finished hand's trump suit, as the live `trump_suit`"
        },
        point_cards: %Schema{
          type: :array,
          items: PointCard,
          description:
            "Every card that scored, in play order; each team's points add up to its `captured`"
        }
      },
      required: [
        :hand_number,
        :bidding_team,
        :bidder,
        :bid,
        :captured,
        :made,
        :delta,
        :scores,
        :trump,
        :point_cards
      ]
    })
  end

  defmodule LastHand do
    @moduledoc "The engine's retained result of the last scored hand."

    OpenApiSpex.schema(%{
      title: "LastHand",
      type: :object,
      nullable: true,
      description:
        "Result retained from scoring until the next hand's first trick completes, including reconnects. Retained at game end; otherwise null when unavailable.",
      properties:
        Map.merge(HandSummary.schema().properties, %{
          bids: %Schema{
            type: :array,
            items: Bid,
            description: "The finished hand's bids, in the live `bids` shape"
          },
          tricks: %Schema{
            type: :array,
            items: Trick,
            description:
              "Every completed trick of the finished hand, including the final one, in the live `tricks` shape"
          }
        }),
      required: HandSummary.schema().required ++ [:bids, :tricks],
      example: %{
        "hand_number" => 3,
        "bidding_team" => "north_south",
        "bidder" => "south",
        "bid" => 9,
        "captured" => %{"north_south" => 8, "east_west" => 6},
        "made" => false,
        "delta" => %{"north_south" => -9, "east_west" => 6},
        "scores" => %{"north_south" => -2, "east_west" => 21},
        "bids" => [%{"position" => "south", "amount" => 9}],
        "trump" => "hearts",
        "tricks" => [],
        "point_cards" => [
          %{
            "card" => %{"rank" => 5, "suit" => "hearts"},
            "points" => 5,
            "position" => "south",
            "team" => "north_south"
          },
          %{
            "card" => %{"rank" => 14, "suit" => "hearts"},
            "points" => 1,
            "position" => "north",
            "team" => "north_south"
          },
          %{
            "card" => %{"rank" => 11, "suit" => "hearts"},
            "points" => 1,
            "position" => "north",
            "team" => "north_south"
          },
          %{
            "card" => %{"rank" => 2, "suit" => "hearts"},
            "points" => 1,
            "position" => "south",
            "team" => "north_south"
          },
          %{
            "card" => %{"rank" => 5, "suit" => "diamonds"},
            "points" => 5,
            "position" => "east",
            "team" => "east_west"
          },
          %{
            "card" => %{"rank" => 10, "suit" => "hearts"},
            "points" => 1,
            "position" => "west",
            "team" => "east_west"
          }
        ]
      }
    })
  end

  defmodule Player do
    @moduledoc "Schema for a Player object representing a player's state in the game."

    OpenApiSpex.schema(%{
      title: "Player",
      description: "A player's current state in the game including hand and stats",
      type: :object,
      properties: %{
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Player position at the table",
          example: :north
        },
        team: %Schema{
          type: :string,
          enum: [:north_south, :east_west],
          description: "Team assignment (north and south vs east and west)",
          example: :north_south
        },
        hand: %Schema{
          type: :array,
          items: Card,
          description: "Cards currently held by the player (nil for opponents in public view)",
          nullable: true,
          example: [
            %{"rank" => 14, "suit" => "hearts"},
            %{"rank" => 13, "suit" => "hearts"}
          ]
        },
        card_count: %Schema{
          type: :integer,
          description: "Number of cards in hand (shown for opponents in public view)",
          minimum: 0,
          nullable: true,
          example: 9
        },
        tricks_won: %Schema{
          type: :integer,
          description: "Number of tricks won by this player",
          minimum: 0,
          maximum: 13,
          example: 3
        },
        eliminated: %Schema{
          type: :boolean,
          description: "Whether the player is eliminated from the round",
          example: false
        },
        revealed_cards: %Schema{
          type: :array,
          description:
            "The viewer's own folded cards after going cold; empty for every other seat and spectators.",
          items: Card,
          example: []
        },
        folded_count: %Schema{
          type: :integer,
          description: "Number of cards folded face down on going cold; zero when not eliminated",
          minimum: 0,
          example: 0
        },
        discarded_count: %Schema{
          type: :integer,
          description:
            "Cards this seat threw in the second deal, shown to every viewer: a non-dealer's from the first deal; the dealer's from the pool they took up (0 if they took none), null while they pick. Null outside the second deal and play.",
          minimum: 0,
          nullable: true,
          example: 4
        }
      },
      required: [:position, :team, :hand, :tricks_won, :eliminated],
      example: %{
        "position" => "north",
        "team" => "north_south",
        "hand" => [
          %{"rank" => 14, "suit" => "hearts"},
          %{"rank" => 13, "suit" => "hearts"}
        ],
        "tricks_won" => 3,
        "eliminated" => false
      }
    })
  end

  defmodule GameStateResponse do
    @moduledoc "Schema for the complex game state response."

    OpenApiSpex.schema(%{
      title: "GameStateResponse",
      description: "Complete game state for a room including all game information",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            state: %Schema{
              type: :object,
              title: "GameState",
              description: "The current game state from Pidro.Server",
              properties: %{
                phase: %Schema{
                  type: :string,
                  enum: [
                    :not_started,
                    :setup,
                    :dealing,
                    :bidding,
                    :trump_selection,
                    :playing,
                    :hand_complete,
                    :completed
                  ],
                  description: "Current phase of the game",
                  example: :bidding
                },
                pace: %Schema{
                  type: :string,
                  enum: ["quick", "own"],
                  description: "Room pace; defaults to quick",
                  example: "quick"
                },
                awaiting_continue: %Schema{
                  type: :boolean,
                  description:
                    "An own-pace hand has scored and waits for continue_hand before dealing",
                  example: false
                },
                hand_number: %Schema{
                  type: :integer,
                  description: "Current hand/round number",
                  minimum: 1,
                  example: 1
                },
                variant: %Schema{
                  type: :string,
                  description: "Game variant being played",
                  enum: Config.rule_sets(),
                  example: "finnish",
                  nullable: true
                },
                config: %Schema{
                  type: :object,
                  description: "Engine configuration for the selected rule set",
                  properties: %{min_bid: %Schema{type: :integer, enum: [6, 7]}}
                },
                current_turn: %Schema{
                  type: :string,
                  enum: [:north, :south, :east, :west],
                  description: "Position of the player whose turn it is",
                  example: :north,
                  nullable: true
                },
                current_dealer: %Schema{
                  type: :string,
                  enum: [:north, :south, :east, :west],
                  description: "Position of the current dealer",
                  example: :west,
                  nullable: true
                },
                players: %Schema{
                  type: :object,
                  additionalProperties: Player,
                  description: "Map of player positions to player states",
                  example: %{
                    "north" => %{
                      "position" => "north",
                      "team" => "north_south",
                      "hand" => [%{"rank" => 14, "suit" => "hearts"}],
                      "tricks_won" => 0,
                      "eliminated" => false
                    }
                  }
                },
                bids: %Schema{
                  type: :array,
                  items: Bid,
                  description: "List of bids made so far in this hand",
                  example: [
                    %{"position" => "west", "amount" => "pass"},
                    %{"position" => "north", "amount" => 8}
                  ]
                },
                highest_bid: %Schema{
                  type: :object,
                  properties: %{
                    position: %Schema{
                      type: :string,
                      enum: [:north, :south, :east, :west],
                      description: "Position of player with highest bid",
                      example: :north
                    },
                    amount: %Schema{
                      type: :integer,
                      minimum: 6,
                      maximum: 14,
                      description: "Highest bid amount",
                      example: 10
                    }
                  },
                  required: [:position, :amount],
                  description: "The highest bid so far in this hand",
                  nullable: true,
                  example: %{"position" => "north", "amount" => 10}
                },
                bidding_team: %Schema{
                  type: :string,
                  enum: [:north_south, :east_west],
                  description: "Team that made the highest bid",
                  example: :north_south,
                  nullable: true
                },
                trump_suit: %Schema{
                  type: :string,
                  enum: [:hearts, :diamonds, :clubs, :spades],
                  description: "Trump suit for this hand",
                  example: :hearts,
                  nullable: true
                },
                killed_cards: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :array, items: Card},
                  description:
                    "Trumps killed over six, by seat, face up for every viewer during play; empty otherwise",
                  example: %{"east" => [%{"rank" => 7, "suit" => "hearts"}]}
                },
                tricks: %Schema{
                  type: :array,
                  items: Trick,
                  description: "List of completed tricks",
                  example: []
                },
                current_trick: %Schema{
                  type: :array,
                  items: Play,
                  description: "Current trick as flat plays (frontend shape)",
                  example: []
                },
                current_trick_details: %Schema{
                  type: :object,
                  properties:
                    Map.put(Trick.schema().properties, :winning, %Schema{
                      type: :object,
                      nullable: true,
                      description:
                        "Play currently winning under the table's variant, or null before the first play",
                      properties: %{
                        position: %Schema{type: :string, enum: [:north, :south, :east, :west]},
                        card: Card
                      },
                      required: [:position, :card]
                    }),
                  required: Trick.schema().required ++ [:winning],
                  description:
                    "Current trick with winning play and points so far; null when no trick exists",
                  nullable: true
                },
                trick_number: %Schema{
                  type: :integer,
                  description: "Current trick number being played",
                  minimum: 1,
                  maximum: 13,
                  example: 1,
                  nullable: true
                },
                hand_points: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :integer},
                  description: "Points earned by each team in this hand",
                  example: %{"north_south" => 0, "east_west" => 0}
                },
                last_hand: LastHand,
                hand_history: %Schema{
                  type: :array,
                  items: HandSummary,
                  description:
                    "Every scored hand of this game, oldest first; kept through game end, empty in a new game"
                },
                scores: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :integer},
                  description: "Total points for each team across all hands",
                  example: %{"north_south" => 0, "east_west" => 0}
                },
                cumulative_scores: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :integer},
                  description: "Deprecated alias for scores (backward compatibility)",
                  example: %{"north_south" => 0, "east_west" => 0}
                },
                winner: %Schema{
                  type: :string,
                  description: "Winner of the game (team name)",
                  example: "north_south",
                  nullable: true
                }
              },
              required: [
                :phase,
                :hand_number,
                :players,
                :bids,
                :tricks,
                :hand_points,
                :scores
              ],
              example: %{
                "phase" => "bidding",
                "hand_number" => 1,
                "variant" => "finnish",
                "current_turn" => "north",
                "current_dealer" => "west",
                "players" => %{
                  "north" => %{
                    "position" => "north",
                    "team" => "north_south",
                    "hand" => [%{"rank" => 14, "suit" => "hearts"}],
                    "tricks_won" => 0,
                    "eliminated" => false
                  },
                  "south" => %{
                    "position" => "south",
                    "team" => "north_south",
                    "hand" => [%{"rank" => 13, "suit" => "hearts"}],
                    "tricks_won" => 0,
                    "eliminated" => false
                  }
                },
                "bids" => [
                  %{"position" => "west", "amount" => "pass"},
                  %{"position" => "north", "amount" => 8}
                ],
                "highest_bid" => %{"position" => "north", "amount" => 8},
                "bidding_team" => "north_south",
                "trump_suit" => nil,
                "tricks" => [],
                "current_trick" => [],
                "current_trick_details" => nil,
                "trick_number" => nil,
                "hand_points" => %{"north_south" => 0, "east_west" => 0},
                "scores" => %{"north_south" => 0, "east_west" => 0},
                "cumulative_scores" => %{"north_south" => 0, "east_west" => 0},
                "winner" => nil
              }
            }
          },
          required: [:state]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "state" => %{
            "phase" => "bidding",
            "hand_number" => 1,
            "variant" => "finnish",
            "current_turn" => "north",
            "current_dealer" => "west",
            "players" => %{
              "north" => %{
                "position" => "north",
                "team" => "north_south",
                "hand" => [%{"rank" => 14, "suit" => "hearts"}],
                "tricks_won" => 0,
                "eliminated" => false
              }
            },
            "bids" => [
              %{"position" => "west", "amount" => "pass"},
              %{"position" => "north", "amount" => 8}
            ],
            "highest_bid" => %{"position" => "north", "amount" => 8},
            "bidding_team" => "north_south",
            "trump_suit" => nil,
            "tricks" => [],
            "current_trick" => [],
            "current_trick_details" => nil,
            "trick_number" => nil,
            "hand_points" => %{"north_south" => 0, "east_west" => 0},
            "scores" => %{"north_south" => 0, "east_west" => 0},
            "cumulative_scores" => %{"north_south" => 0, "east_west" => 0},
            "winner" => nil
          }
        }
      }
    })
  end
end
