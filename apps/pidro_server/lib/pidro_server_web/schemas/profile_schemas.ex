defmodule PidroServerWeb.Schemas.ProfileSchemas do
  @moduledoc """
  OpenAPI schemas for the player profile API (PID-54).

  Documents the full profile screen returned by `GET /api/v1/profile`:
  headline lifetime stats, skill tier + provisional state, veteran
  progression, heritage badges, playstyle, and mastery achievements.

  The raw rating internals (`rating_mu`, `rating_sigma`, `rating_games_count`)
  are intentionally ABSENT from this schema — skill is exposed only as a derived
  `tier` + `provisional` state. The schema itself documents the exclusion.

  Uses OpenApiSpex.Schema for type safety and documentation.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule AvatarFaceRequest do
    @moduledoc "Body of `PUT /api/v1/profile/avatar/face` (PID-395)."

    OpenApiSpex.schema(%{
      type: :object,
      title: "Avatar Face Request",
      required: [:face],
      properties: %{
        face: %Schema{
          type: :string,
          enum: ["a", "b"],
          description: "Face 1 (`a`) or Face 2 (`b`), the app's avatar1.png and avatar2.png"
        }
      },
      example: %{"face" => "b"}
    })
  end

  defmodule PlayerProfileResponse do
    @moduledoc """
    Response containing the authenticated user's full profile screen.

    Includes headline lifetime stats, skill (tier + provisional state only —
    NO raw μ/σ), veteran progression, heritage badges, playstyle, and mastery
    achievements. All keys are snake_case and wrapped in a `data` envelope.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Player Profile Response",
      description: "Response containing the authenticated user's full profile screen",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope containing the player profile",
          properties: %{
            user_id: %Schema{
              type: :string,
              format: :uuid,
              description: "The profile owner's user id",
              example: "b1f0c2e4-1111-2222-3333-444455556666"
            },
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
              description: "Win rate as a decimal (0.0 to 1.0, or 0.0 if no games played)",
              minimum: 0.0,
              maximum: 1.0,
              example: 0.595
            },
            first_seen_at: %Schema{
              type: :string,
              format: "date-time",
              nullable: true,
              description: "When the account was first seen (account creation time)",
              example: "2025-11-02T08:14:00Z"
            },
            account_age_days: %Schema{
              type: :integer,
              nullable: true,
              description: "Age of the account in whole days",
              minimum: 0,
              example: 217
            },
            skill: %Schema{
              type: :object,
              description:
                "Derived skill tier + provisional state. The raw rating internals " <>
                  "(mu/sigma/rated-game count) are intentionally NOT exposed.",
              properties: %{
                tier: %Schema{
                  type: :string,
                  description: "The player's skill tier (or the provisional gate)",
                  enum: ["provisional", "bronze", "silver", "gold", "platinum", "master"],
                  example: "gold"
                },
                provisional: %Schema{
                  type: :boolean,
                  description:
                    "True while the player has too few rated games or too high uncertainty",
                  example: false
                }
              },
              required: [:tier, :provisional]
            },
            veteran: %Schema{
              type: :object,
              description: "Veteran progression: level, XP, title, and progress to next level",
              properties: %{
                level: %Schema{
                  type: :integer,
                  description: "Current veteran level",
                  minimum: 0,
                  example: 7
                },
                xp: %Schema{
                  type: :integer,
                  description: "Lifetime veteran XP",
                  minimum: 0,
                  example: 1480
                },
                title: %Schema{
                  type: :string,
                  description: "Title for the current level",
                  example: "Seasoned"
                },
                progress: %Schema{
                  description:
                    "Progress into the current level as a `[into, span]` integer pair, " <>
                      "or the string \"max\" once the level cap is reached",
                  oneOf: [
                    %Schema{
                      type: :array,
                      items: %Schema{type: :integer},
                      minItems: 2,
                      maxItems: 2,
                      example: [120, 210]
                    },
                    %Schema{type: :string, enum: ["max"]}
                  ],
                  example: [120, 210]
                }
              },
              required: [:level, :xp, :title, :progress]
            },
            xp: %Schema{
              type: :object,
              description:
                "XP earned this week (from Monday 00:00) and this calendar month, both UTC. All-time XP is `veteran.xp`.",
              properties: %{
                this_week: %Schema{type: :integer, minimum: 0, example: 240},
                this_month: %Schema{type: :integer, minimum: 0, example: 910}
              },
              required: [:this_week, :this_month]
            },
            record: %Schema{
              type: :object,
              description:
                "One record where Classic games and Pidro 2 games add up; Pidro 2 alone without a Classic account",
              properties: %{
                games: %Schema{type: :integer, minimum: 0, example: 35_321},
                wins: %Schema{type: :integer, minimum: 0, example: 18_265},
                losses: %Schema{type: :integer, minimum: 0, example: 17_056},
                win_rate: %Schema{
                  type: :number,
                  format: :double,
                  minimum: 0.0,
                  maximum: 1.0,
                  example: 0.517
                }
              },
              required: [:games, :wins, :losses, :win_rate]
            },
            heritage: %Schema{
              type: :array,
              description:
                "Display list of heritage badges (e.g. Pidro 1 veteran, founding member)",
              items: %Schema{
                type: :object,
                properties: %{
                  key: %Schema{type: :string, example: "founding_member"},
                  label: %Schema{type: :string, example: "Founding Member"},
                  value: %Schema{description: "Badge value (typically boolean)", example: true}
                },
                required: [:key, :label, :value]
              },
              example: [
                %{"key" => "played_pidro_one", "label" => "Played Pidro 1", "value" => true},
                %{"key" => "founding_member", "label" => "Founding Member", "value" => true}
              ]
            },
            classic: %Schema{
              type: :object,
              nullable: true,
              description:
                "Classic career summary, or null before a claim. Missing career values are omitted.",
              properties: %{
                name: %Schema{
                  type: :string,
                  description: "Classic public name, present only when approved for display",
                  example: "Veteran"
                },
                games_played: %Schema{type: :integer, minimum: 0, example: 35_279},
                wins: %Schema{type: :integer, minimum: 0, example: 18_240},
                losses: %Schema{type: :integer, minimum: 0, example: 17_039},
                win_rate: %Schema{
                  type: :number,
                  format: :double,
                  minimum: 0.0,
                  maximum: 1.0,
                  example: 0.517
                },
                level: %Schema{type: :integer, minimum: 0, example: 73},
                member_since: %Schema{
                  type: :string,
                  format: "date-time",
                  example: "2013-04-12T09:30:00Z"
                },
                claimed_at: %Schema{
                  type: :string,
                  format: "date-time",
                  description: "When the Classic account was attached",
                  example: "2026-09-27T18:30:00Z"
                }
              }
            },
            playstyle: %Schema{
              type: :object,
              description:
                "Bidding playstyle: win rate, aggression meter + label, avg winning bid",
              properties: %{
                bidding_win_rate: %Schema{
                  type: :number,
                  format: :double,
                  nullable: true,
                  description:
                    "Bidding win rate (0.0 to 1.0); null when there is insufficient data",
                  example: 0.61
                },
                aggression_needle: %Schema{
                  type: :number,
                  format: :double,
                  description:
                    "Aggression meter position (0.0 to 1.0; 0.5 when insufficient data)",
                  example: 0.72
                },
                aggression_label: %Schema{
                  type: :string,
                  description: "Human-readable aggression label",
                  example: "Aggressive"
                },
                aggression_insufficient: %Schema{
                  type: :boolean,
                  description:
                    "True when there is not enough bidding data to characterize playstyle",
                  example: false
                },
                avg_winning_bid: %Schema{
                  type: :number,
                  format: :double,
                  nullable: true,
                  description: "Average winning bid; null when the player has never won a bid",
                  example: 9.4
                }
              },
              required: [
                :bidding_win_rate,
                :aggression_needle,
                :aggression_label,
                :aggression_insufficient,
                :avg_winning_bid
              ]
            },
            achievements: %Schema{
              type: :array,
              description: "Earned achievements, joined to the catalog for display copy",
              items: %Schema{
                type: :object,
                properties: %{
                  key: %Schema{type: :string, example: "first_win"},
                  name: %Schema{type: :string, example: "First Win"},
                  description: %Schema{type: :string, example: "Win your first game"},
                  tier: %Schema{type: :integer, example: 1},
                  awarded_at: %Schema{
                    type: :string,
                    format: "date-time",
                    example: "2025-11-05T19:30:00Z"
                  }
                },
                required: [:key, :name, :description, :tier, :awarded_at]
              }
            },
            achievements_catalog: %Schema{
              type: :array,
              description: "Active achievement catalog annotated with an `earned` flag",
              items: %Schema{
                type: :object,
                properties: %{
                  key: %Schema{type: :string, example: "ten_wins"},
                  name: %Schema{type: :string, example: "Ten Wins"},
                  description: %Schema{type: :string, example: "Win ten games"},
                  tier: %Schema{type: :integer, example: 2},
                  earned: %Schema{type: :boolean, example: false}
                },
                required: [:key, :name, :description, :tier, :earned]
              }
            }
          },
          required: [
            :user_id,
            :games_played,
            :wins,
            :losses,
            :win_rate,
            :first_seen_at,
            :account_age_days,
            :skill,
            :veteran,
            :xp,
            :record,
            :heritage,
            :classic,
            :playstyle,
            :achievements,
            :achievements_catalog
          ]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "user_id" => "b1f0c2e4-1111-2222-3333-444455556666",
          "games_played" => 42,
          "wins" => 25,
          "losses" => 17,
          "win_rate" => 0.595,
          "first_seen_at" => "2025-11-02T08:14:00Z",
          "account_age_days" => 217,
          "skill" => %{"tier" => "gold", "provisional" => false},
          "veteran" => %{
            "level" => 7,
            "xp" => 1480,
            "title" => "Seasoned",
            "progress" => [120, 210]
          },
          "xp" => %{"this_week" => 240, "this_month" => 910},
          "record" => %{
            "games" => 35_321,
            "wins" => 18_265,
            "losses" => 17_056,
            "win_rate" => 0.517
          },
          "heritage" => [
            %{"key" => "played_pidro_one", "label" => "Played Pidro 1", "value" => true},
            %{"key" => "founding_member", "label" => "Founding Member", "value" => true}
          ],
          "classic" => %{
            "name" => "Veteran",
            "games_played" => 35_279,
            "wins" => 18_240,
            "losses" => 17_039,
            "win_rate" => 0.517,
            "level" => 73,
            "member_since" => "2013-04-12T09:30:00Z",
            "claimed_at" => "2026-09-27T18:30:00Z"
          },
          "playstyle" => %{
            "bidding_win_rate" => 0.61,
            "aggression_needle" => 0.72,
            "aggression_label" => "Aggressive",
            "aggression_insufficient" => false,
            "avg_winning_bid" => 9.4
          },
          "achievements" => [
            %{
              "key" => "first_win",
              "name" => "First Win",
              "description" => "Win your first game",
              "tier" => 1,
              "awarded_at" => "2025-11-05T19:30:00Z"
            }
          ],
          "achievements_catalog" => [
            %{
              "key" => "first_win",
              "name" => "First Win",
              "description" => "Win your first game",
              "tier" => 1,
              "earned" => true
            },
            %{
              "key" => "ten_wins",
              "name" => "Ten Wins",
              "description" => "Win ten games",
              "tier" => 2,
              "earned" => false
            }
          ]
        }
      }
    })
  end

  defmodule PublicProfileResponse do
    @moduledoc """
    Another player's sheet: public identity, level and Legend stars, the
    Classic years, the combined record, the medal count, and the viewer's
    games with this player.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Public Profile Response",
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [
            :user_id,
            :username,
            :display_name,
            :avatar_url,
            :bio,
            :level,
            :prestige,
            :title,
            :pin,
            :classic,
            :record,
            :medals,
            :together
          ],
          properties: %{
            user_id: %Schema{type: :string, format: :uuid},
            username: %Schema{type: :string, nullable: true},
            display_name: %Schema{type: :string, nullable: true},
            avatar_url: %Schema{type: :string, nullable: true},
            bio: %Schema{type: :string, nullable: true},
            level: %Schema{type: :integer, minimum: 1, maximum: 100, example: 100},
            prestige: %Schema{
              type: :integer,
              minimum: 0,
              description: "Legend stars, one per 500,000 XP past level 100 (0 below that)",
              example: 4
            },
            title: %Schema{type: :string, example: "Legend"},
            pin: %Schema{
              type: :string,
              enum: ["classic"],
              nullable: true,
              description: "\"classic\" for a claimed Classic account, else null"
            },
            classic: %Schema{
              type: :object,
              nullable: true,
              description: "The Classic years, or null for a player who never played Classic",
              required: [:username, :member_since, :games_played],
              properties: %{
                username: %Schema{
                  type: :string,
                  nullable: true,
                  description: "Classic name, null unless approved for display"
                },
                member_since: %Schema{type: :string, format: "date-time", nullable: true},
                games_played: %Schema{type: :integer, minimum: 0, nullable: true}
              }
            },
            record: %Schema{
              type: :object,
              description: "Pidro 2 and Classic games added up, as on the player's own profile",
              required: [:games, :win_rate],
              properties: %{
                games: %Schema{type: :integer, minimum: 0, example: 10_420},
                win_rate: %Schema{
                  type: :number,
                  format: :double,
                  minimum: 0.0,
                  maximum: 1.0,
                  example: 0.53
                }
              }
            },
            medals: %Schema{type: :integer, minimum: 0, description: "Achievements earned"},
            together: %Schema{
              type: :object,
              description:
                "Completed Pidro 2 games the viewer played with this player; all zeros on your own sheet",
              required: [:games, :won_as_partners, :against_games, :against_won],
              properties: %{
                games: %Schema{type: :integer, minimum: 0, description: "Every game together"},
                won_as_partners: %Schema{type: :integer, minimum: 0},
                against_games: %Schema{type: :integer, minimum: 0},
                against_won: %Schema{
                  type: :integer,
                  minimum: 0,
                  description: "Games against this player that the viewer won"
                }
              }
            }
          }
        }
      }
    })
  end
end
