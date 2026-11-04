defmodule PidroServerWeb.Schemas.LeagueSchemas do
  @moduledoc "Shared raw league contract (PID-350–352)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  defmodule Ribbon do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "LeagueRibbon",
      type: :object,
      required: [:month, :league, :star, :weeks_played, :weeks_total, :so_far, :star_possible],
      properties: %{
        month: %Schema{type: :string},
        league: %Schema{type: :string, enum: ~w(deuce ten jack ace pidro)},
        star: %Schema{type: :boolean},
        weeks_played: %Schema{type: :integer},
        weeks_total: %Schema{type: :integer},
        so_far: %Schema{type: :boolean},
        star_possible: %Schema{type: :boolean},
        changed: %Schema{type: :boolean}
      }
    })
  end

  defmodule Result do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "LeagueResult",
      type: :object,
      nullable: true,
      required: [
        :id,
        :week_starts_at,
        :week_closes_at,
        :old_league,
        :new_league,
        :move,
        :place,
        :points,
        :room_size,
        :ribbon
      ],
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        week_starts_at: %Schema{type: :string, format: :"date-time"},
        week_closes_at: %Schema{type: :string, format: :"date-time"},
        old_league: %Schema{type: :string, enum: ~w(deuce ten jack ace pidro)},
        new_league: %Schema{type: :string, enum: ~w(deuce ten jack ace pidro)},
        move: %Schema{type: :string, enum: ~w(up stayed down)},
        place: %Schema{type: :integer},
        points: %Schema{type: :integer},
        room_size: %Schema{type: :integer},
        ribbon: Ribbon
      }
    })
  end

  defmodule Standing do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "LeagueStanding",
      type: :object,
      required: [:place, :user_id, :username, :avatar, :level, :prestige, :pin, :points, :me],
      properties: %{
        place: %Schema{type: :integer},
        user_id: %Schema{type: :string, format: :uuid},
        username: %Schema{type: :string},
        avatar: %Schema{
          type: :object,
          required: [:url],
          properties: %{url: %Schema{type: :string, nullable: true}}
        },
        level: %Schema{type: :integer},
        prestige: %Schema{type: :integer},
        pin: %Schema{type: :string, nullable: true},
        points: %Schema{type: :integer},
        me: %Schema{type: :boolean}
      }
    })
  end

  defmodule Friend do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "LeagueFriend",
      type: :object,
      required: [:user_id, :username, :avatar, :level, :prestige, :league, :place],
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        username: %Schema{type: :string},
        avatar: %Schema{
          type: :object,
          required: [:url],
          properties: %{url: %Schema{type: :string, nullable: true}}
        },
        level: %Schema{type: :integer},
        prestige: %Schema{type: :integer},
        league: %Schema{type: :string, enum: ~w(deuce ten jack ace pidro)},
        place: %Schema{type: :integer}
      }
    })
  end

  defmodule Response do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "LeagueResponse",
      type: :object,
      required: [
        :status,
        :league,
        :week,
        :room,
        :me,
        :last_week,
        :pending_result,
        :friends,
        :ribbons,
        :intro_seen,
        :classic
      ],
      properties: %{
        status: %Schema{type: :string, enum: ~w(placed not_placed opted_out guest off)},
        league: %Schema{type: :string, nullable: true, enum: ~w(deuce ten jack ace pidro)},
        week: %Schema{
          type: :object,
          nullable: true,
          required: [:starts_at, :closes_at],
          properties: %{
            starts_at: %Schema{type: :string, format: :"date-time"},
            closes_at: %Schema{type: :string, format: :"date-time"}
          }
        },
        room: %Schema{
          type: :object,
          nullable: true,
          required: [:size, :promote, :demote, :standings],
          properties: %{
            size: %Schema{type: :integer},
            promote: %Schema{type: :integer},
            demote: %Schema{type: :integer},
            standings: %Schema{type: :array, items: Standing}
          }
        },
        me: %Schema{
          type: :object,
          nullable: true,
          required: [:place, :points],
          properties: %{place: %Schema{type: :integer}, points: %Schema{type: :integer}}
        },
        last_week: %Schema{
          type: :object,
          nullable: true,
          required: [:league, :place, :room_size, :points],
          properties: %{
            league: %Schema{type: :string},
            place: %Schema{type: :integer},
            room_size: %Schema{type: :integer},
            points: %Schema{type: :integer}
          }
        },
        pending_result: Result,
        friends: %Schema{type: :array, items: Friend},
        ribbons: %Schema{
          type: :object,
          required: [:current, :past],
          properties: %{
            current: %Schema{allOf: [Ribbon], nullable: true},
            past: %Schema{type: :array, items: Ribbon}
          }
        },
        intro_seen: %Schema{type: :boolean},
        classic: %Schema{type: :boolean}
      }
    })
  end

  defmodule Hidden do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "LeagueHidden",
      type: :object,
      required: [:hidden],
      properties: %{hidden: %Schema{type: :boolean}}
    })
  end
end
