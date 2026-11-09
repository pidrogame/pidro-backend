defmodule PidroServer.Games.Room.Seat do
  @moduledoc """
  Represents a position at the table that can be occupied by a human, bot, or
  left vacant.

  Each seat tracks its occupant type, connection status, and the disconnect
  cascade state. All transition functions validate the current state and return
  `{:ok, updated_seat}` or `{:error, reason}`.

  ## Valid State Transitions

      connected -> reconnecting       (disconnect/1)
      reconnecting -> connected        (reclaim/2)
      reconnecting -> grace            (start_grace/2)
      grace -> connected               (reclaim/2)
      grace -> bot_substitute          (substitute_bot/2)
      bot_substitute -> connected      (reclaim/2, when reserved_for matches)
      bot_substitute -> vacant         (open_for_substitute/1)
      vacant -> connected              (fill_seat/2)
      human/bot occupied -> bot_substitute (surrender/2, permanent, no reclaim)
  """

  @type position :: :north | :east | :south | :west
  @type occupant_type :: :human | :bot | :vacant
  @type status :: :connected | :reconnecting | :grace | :bot_substitute

  @type t :: %__MODULE__{
          position: position(),
          occupant_type: occupant_type(),
          user_id: String.t() | nil,
          bot_pid: pid() | nil,
          status: status() | nil,
          disconnected_at: DateTime.t() | nil,
          grace_expires_at: DateTime.t() | nil,
          reserved_for: String.t() | nil,
          is_owner: boolean(),
          joined_at: DateTime.t() | nil,
          substitute: boolean(),
          decision_id: String.t() | nil,
          decision_player_id: String.t() | nil,
          vacated_by: String.t() | nil,
          bot_persona: bot_persona() | nil,
          bot_strategy: module() | nil
        }

  @typedoc "The crew a real bot seat is named after; substitute bots have none."
  @type bot_persona :: String.t()

  @bot_personas ~w(marcel antti jocke)

  defstruct [
    :position,
    :occupant_type,
    :user_id,
    :bot_pid,
    :status,
    :disconnected_at,
    :grace_expires_at,
    :reserved_for,
    :decision_id,
    :decision_player_id,
    :vacated_by,
    :bot_persona,
    :bot_strategy,
    :app_version,
    :app_build,
    :platform,
    :reason,
    :network,
    :background_token,
    :pending_ping,
    :connection_stats,
    liveness_enabled: false,
    missed_pings: 0,
    round_trips: [],
    is_owner: false,
    joined_at: nil,
    substitute: false
  ]

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc "Latest and median of the last twenty answered connection probes, in milliseconds."
  @spec connection_latency(t()) :: %{latest_ms: number() | nil, median_ms: number() | nil}
  def connection_latency(%__MODULE__{round_trips: []}), do: %{latest_ms: nil, median_ms: nil}

  def connection_latency(%__MODULE__{round_trips: [latest | _] = samples}) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    median = (Enum.at(sorted, div(n - 1, 2)) + Enum.at(sorted, div(n, 2))) / 2
    %{latest_ms: latest, median_ms: median}
  end

  @doc "Starts this human's per-game counters; timestamps are restart-safe Unix milliseconds."
  def start_connection_stats(seat, now \\ System.system_time(:millisecond)) do
    stats =
      if seat.user_id || seat.reserved_for do
        %{
          started_ms: now,
          ended_ms: nil,
          network_started_ms: now,
          network_ms: %{},
          checks_sent: 0,
          rtt_histogram: %{},
          drops: 0,
          disconnected_ms: 0,
          disconnected_since_ms: if(seat.disconnected_at, do: now)
        }
      end

    %{seat | connection_stats: stats, round_trips: []}
  end

  @doc "Counts a sent probe. Any probe without a pong is unanswered, including cancellation."
  def record_connection_probe(%{connection_stats: nil} = seat), do: seat
  def record_connection_probe(seat), do: update_in(seat.connection_stats.checks_sent, &(&1 + 1))

  @doc "Adds a round-trip frequency, without retaining a timestamped probe log."
  def record_connection_reply(%{connection_stats: nil} = seat, _elapsed), do: seat

  def record_connection_reply(seat, elapsed) do
    update_in(
      seat.connection_stats.rtt_histogram,
      &Map.update(&1, to_string(elapsed), 1, fn n -> n + 1 end)
    )
  end

  @doc "Closes the previous connection's network interval before recording the new network."
  def connection_network(seat, network, now \\ System.system_time(:millisecond))

  def connection_network(%{connection_stats: nil} = seat, network, _now),
    do: %{seat | network: network}

  def connection_network(seat, network, now) do
    stats = seat.connection_stats
    now = stats.ended_ms || now

    %{
      seat
      | network: network,
        connection_stats: %{
          stats
          | network_ms: network_totals(seat, now),
            network_started_ms: now
        }
    }
  end

  @doc "Closes the current absence before reclaim clears its timestamps."
  def connection_returned(seat, now \\ System.system_time(:millisecond))
  def connection_returned(%{connection_stats: nil} = seat, _now), do: seat

  def connection_returned(seat, now) do
    stats = seat.connection_stats
    now = stats.ended_ms || now

    %{
      seat
      | connection_stats: %{
          stats
          | disconnected_ms: disconnected_total(stats, now),
            disconnected_since_ms: nil
        }
    }
  end

  @doc "Freezes playing time and open intervals when the game ends."
  def finish_connection_stats(seat, now \\ System.system_time(:millisecond))
  def finish_connection_stats(%{connection_stats: nil} = seat, _now), do: seat
  def finish_connection_stats(seat, now), do: put_in(seat.connection_stats.ended_ms, now)

  @doc "Starts a deployment-induced absence without counting a player drop."
  def restore_connection_stats(%{connection_stats: nil} = seat), do: seat

  def restore_connection_stats(seat) do
    update_in(
      seat.connection_stats.disconnected_since_ms,
      &(&1 || DateTime.to_unix(seat.disconnected_at, :millisecond))
    )
  end

  @doc "Current per-game totals, including any still-open absence and network interval."
  def connection_totals(seat, now \\ System.system_time(:millisecond))
  def connection_totals(%{connection_stats: nil}, _now), do: nil

  def connection_totals(seat, now) do
    stats = seat.connection_stats
    now = stats.ended_ms || now

    %{
      checks_sent: stats.checks_sent,
      unanswered_checks: stats.checks_sent - Enum.sum(Map.values(stats.rtt_histogram)),
      rtt_histogram: stats.rtt_histogram,
      drops: stats.drops,
      duration_seconds: max(0, now - stats.started_ms) / 1000,
      disconnected_seconds: disconnected_total(stats, now) / 1000,
      network_ms: network_totals(seat, now)
    }
  end

  defp disconnected_total(stats, now) do
    stats.disconnected_ms +
      if(stats.disconnected_since_ms, do: max(0, now - stats.disconnected_since_ms), else: 0)
  end

  defp network_totals(seat, now) do
    elapsed = max(0, now - seat.connection_stats.network_started_ms)

    Map.update(
      seat.connection_stats.network_ms,
      seat.network || "unknown",
      elapsed,
      &(&1 + elapsed)
    )
  end

  @doc """
  Creates a new seat occupied by a connected human player.

  ## Options

    * `:is_owner` - whether this player is the room owner (default: `false`)
    * `:joined_at` - when the player joined (default: `DateTime.utc_now/0`)
  """
  @spec new_human(position(), String.t(), keyword()) :: t()
  def new_human(position, user_id, opts \\ []) do
    %__MODULE__{
      position: position,
      occupant_type: :human,
      user_id: user_id,
      status: :connected,
      is_owner: Keyword.get(opts, :is_owner, false),
      joined_at: Keyword.get(opts, :joined_at, DateTime.utc_now())
    }
  end

  @doc "Creates a new seat occupied by a bot, named after `bot_persona`; its process may attach later."
  @spec new_bot(position(), pid() | nil, bot_persona() | nil) :: t()
  def new_bot(position, bot_pid, bot_persona \\ nil) do
    %__MODULE__{
      position: position,
      occupant_type: :bot,
      bot_pid: bot_pid,
      status: :connected,
      bot_persona: bot_persona,
      bot_strategy: persona_strategy(bot_persona)
    }
  end

  @doc "The bot crew, before the room shuffles its order."
  @spec bot_personas() :: [bot_persona()]
  def bot_personas, do: Enum.map(PidroServer.BotCatalogue.available(), & &1.id)

  @doc """
  The bot crew for a table of `rule_set`, in two groups the room shuffles apart:
  the characters at home there or anywhere, then the rest. Missing is Finnish.
  """
  @spec bot_personas(:finnish | :louisiana | nil) :: [[bot_persona()]]
  def bot_personas(rule_set) do
    home = if rule_set == :louisiana, do: "louisiana", else: "finland"

    {own, rest} =
      Enum.split_with(PidroServer.BotCatalogue.available(), &(&1.home in [home, "anywhere"]))

    for group <- [own, rest], do: Enum.map(group, & &1.id)
  end

  @doc """
  The first persona in the room's crew order no other seat holds or was chosen
  for. Only enabled profiles enter new seats; when exhausted, reuse the first
  nobody chose.
  """
  @spec next_bot_persona(map(), [bot_persona()], [bot_persona()]) :: bot_persona()
  def next_bot_persona(seats, order \\ @bot_personas, chosen \\ []) when is_map(seats) do
    available = bot_personas()
    order = Enum.filter(order, &(&1 in available)) ++ (available -- order)
    taken = chosen ++ for {_position, %__MODULE__{bot_persona: persona}} <- seats, do: persona

    Enum.find(order, &(&1 not in taken)) ||
      Enum.find(order, hd(order), &(&1 not in chosen))
  end

  @doc "The name a bot persona shows at the table."
  @spec bot_display_name(bot_persona()) :: String.t()
  def bot_display_name(persona) do
    case PidroServer.BotCatalogue.profile(persona) do
      nil -> "Bot"
      profile -> profile.name
    end
  end

  defp persona_strategy(nil), do: nil

  defp persona_strategy(persona) do
    case Enum.find(PidroServer.BotCatalogue.available(), &(&1.id == persona)) do
      nil -> PidroServer.BotCatalogue.strategy("rulebook")
      profile -> PidroServer.BotCatalogue.strategy(profile.strategy)
    end
  end

  @doc "Creates a new vacant seat."
  @spec new_vacant(position()) :: t()
  def new_vacant(position) do
    %__MODULE__{
      position: position,
      occupant_type: :vacant,
      status: nil
    }
  end

  # ---------------------------------------------------------------------------
  # State Transitions
  # ---------------------------------------------------------------------------

  @doc """
  Marks a connected human seat as reconnecting. Sets `disconnected_at`.

  Valid from: `:connected` (human only)
  """
  @spec disconnect(t()) :: {:ok, t()} | {:error, atom()}
  def disconnect(%__MODULE__{status: :connected, occupant_type: :human} = seat) do
    stats = seat.connection_stats

    stats =
      if stats,
        do: %{
          stats
          | drops: stats.drops + 1,
            disconnected_since_ms: System.system_time(:millisecond)
        }

    {:ok,
     %{seat | status: :reconnecting, disconnected_at: DateTime.utc_now(), connection_stats: stats}}
  end

  def disconnect(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Transitions a reconnecting seat to grace period. Sets `grace_expires_at` and
  `reserved_for` so the original player can reclaim later.

  Valid from: `:reconnecting`
  """
  @spec start_grace(t(), DateTime.t()) :: {:ok, t()} | {:error, atom()}
  def start_grace(%__MODULE__{status: :reconnecting, user_id: user_id} = seat, grace_expires_at) do
    {:ok, %{seat | status: :grace, grace_expires_at: grace_expires_at, reserved_for: user_id}}
  end

  def start_grace(%__MODULE__{}, _), do: {:error, :invalid_transition}

  @doc """
  Replaces the human with a substitute bot. Swaps occupant_type to `:bot`,
  stores the bot pid, and clears the human user_id.

  Valid from: `:grace`
  """
  @spec substitute_bot(t(), pid()) :: {:ok, t()} | {:error, atom()}
  def substitute_bot(%__MODULE__{status: :grace} = seat, bot_pid) do
    {:ok, %{seat | status: :bot_substitute, occupant_type: :bot, bot_pid: bot_pid, user_id: nil}}
  end

  def substitute_bot(%__MODULE__{}, _), do: {:error, :invalid_transition}

  @doc """
  Makes a bot substitute permanent by clearing `reserved_for`. The original
  human can no longer reclaim this seat, so it has no grace deadline either.

  Valid from: `:bot_substitute`
  """
  @spec make_permanent_bot(t()) :: {:ok, t()} | {:error, atom()}
  def make_permanent_bot(%__MODULE__{status: :bot_substitute, reserved_for: player_id} = seat)
      when not is_nil(player_id) do
    {:ok,
     %{
       seat
       | reserved_for: nil,
         grace_expires_at: nil,
         decision_id: Ecto.UUID.generate(),
         decision_player_id: player_id
     }}
  end

  def make_permanent_bot(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc "Surrenders an occupied seat to a permanent bot after explicit departure."
  @spec surrender(t(), pid()) :: {:ok, t()} | {:error, :invalid_transition}
  # Repeated departure cleanup is not a new generation, even after Keep Bot.
  def surrender(
        %__MODULE__{occupant_type: :bot, status: :bot_substitute, reserved_for: nil} = seat,
        bot_pid
      )
      when is_pid(bot_pid), do: {:ok, %{seat | bot_pid: bot_pid}}

  def surrender(%__MODULE__{occupant_type: type} = seat, bot_pid)
      when type in [:human, :bot] and is_pid(bot_pid) do
    player_id = seat.user_id || seat.reserved_for || seat.decision_player_id
    decision_id = seat.decision_id || Ecto.UUID.generate()

    {:ok,
     %{
       seat
       | occupant_type: :bot,
         status: :bot_substitute,
         bot_pid: bot_pid,
         user_id: nil,
         reserved_for: nil,
         decision_id: decision_id,
         decision_player_id: player_id,
         disconnected_at: nil,
         grace_expires_at: nil,
         connection_stats: nil,
         round_trips: []
     }}
  end

  def surrender(%__MODULE__{}, _), do: {:error, :invalid_transition}

  @doc "Consumes a departure decision without changing the bot's control of the seat."
  @spec keep_bot(t(), String.t()) :: {:ok, t()} | {:error, :stale_decision}
  def keep_bot(
        %__MODULE__{
          occupant_type: :bot,
          status: :bot_substitute,
          reserved_for: nil,
          decision_id: id
        } = seat,
        id
      )
      when is_binary(id) and byte_size(id) > 0 do
    {:ok, %{seat | decision_id: nil, decision_player_id: nil}}
  end

  def keep_bot(%__MODULE__{}, _), do: {:error, :stale_decision}

  @doc """
  Reclaims a seat for the original human. Restores the seat to `:connected`
  with occupant_type `:human`. Only succeeds if `user_id` matches the
  `reserved_for` field (or the seat's own `user_id` during Phase 1).

  Valid from: `:reconnecting`, `:grace`, or `:bot_substitute` (with `reserved_for`)
  """
  @spec reclaim(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def reclaim(%__MODULE__{status: :reconnecting, user_id: user_id} = seat, reclaiming_user_id)
      when user_id == reclaiming_user_id do
    {:ok,
     %{
       seat
       | status: :connected,
         disconnected_at: nil,
         decision_id: nil,
         decision_player_id: nil
     }}
  end

  def reclaim(
        %__MODULE__{status: :grace, reserved_for: reserved_for} = seat,
        reclaiming_user_id
      )
      when reserved_for == reclaiming_user_id do
    {:ok,
     %{
       seat
       | status: :connected,
         occupant_type: :human,
         user_id: reclaiming_user_id,
         bot_pid: nil,
         disconnected_at: nil,
         grace_expires_at: nil,
         reserved_for: nil,
         decision_id: nil,
         decision_player_id: nil
     }}
  end

  def reclaim(
        %__MODULE__{status: :bot_substitute, reserved_for: reserved_for} = seat,
        reclaiming_user_id
      )
      when reserved_for != nil and reserved_for == reclaiming_user_id do
    {:ok,
     %{
       seat
       | status: :connected,
         occupant_type: :human,
         user_id: reclaiming_user_id,
         bot_pid: nil,
         disconnected_at: nil,
         grace_expires_at: nil,
         reserved_for: nil,
         decision_id: nil,
         decision_player_id: nil
     }}
  end

  def reclaim(%__MODULE__{status: status}, _)
      when status in [:reconnecting, :grace, :bot_substitute],
      do: {:error, :user_mismatch}

  def reclaim(%__MODULE__{}, _), do: {:error, :invalid_transition}

  @doc """
  Opens a bot-substitute seat for a new human to join.

  Valid from: `:bot_substitute`
  """
  @spec open_for_substitute(t()) :: {:ok, t()} | {:error, atom()}
  def open_for_substitute(%__MODULE__{status: :bot_substitute} = seat) do
    {:ok,
     %{
       seat
       | status: nil,
         occupant_type: :vacant,
         bot_pid: nil,
         bot_persona: nil,
         user_id: nil,
         reserved_for: nil,
         disconnected_at: nil,
         grace_expires_at: nil,
         decision_id: nil,
         decision_player_id: nil
     }}
  end

  def open_for_substitute(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Fills a vacant seat with a new human player.

  Valid from: vacant (status `nil`, occupant_type `:vacant`)
  """
  @spec fill_seat(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def fill_seat(%__MODULE__{occupant_type: :vacant, status: nil} = seat, user_id) do
    {:ok,
     %{
       seat
       | status: :connected,
         occupant_type: :human,
         user_id: user_id,
         joined_at: DateTime.utc_now(),
         substitute: true,
         vacated_by: nil,
         decision_id: nil,
         decision_player_id: nil,
         connection_stats: nil,
         round_trips: [],
         pending_ping: nil,
         liveness_enabled: false,
         missed_pings: 0,
         app_version: nil,
         app_build: nil,
         platform: nil,
         network: nil,
         reason: nil
     }}
  end

  def fill_seat(%__MODULE__{}, _), do: {:error, :invalid_transition}

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc "Returns true if the seat has a connected human occupant."
  @spec connected_human?(t()) :: boolean()
  def connected_human?(%__MODULE__{status: :connected, occupant_type: :human}), do: true
  def connected_human?(%__MODULE__{}), do: false

  @doc "Returns true if the seat has an active bot (connected or substitute)."
  @spec active_bot?(t()) :: boolean()
  def active_bot?(%__MODULE__{occupant_type: :bot, bot_pid: pid}) when is_pid(pid), do: true
  def active_bot?(%__MODULE__{}), do: false

  @doc "Returns true if the given user_id can reclaim this seat."
  @spec can_reclaim?(t(), String.t()) :: boolean()
  def can_reclaim?(%__MODULE__{status: :reconnecting, user_id: uid}, user_id), do: uid == user_id

  def can_reclaim?(%__MODULE__{status: :grace, reserved_for: reserved}, user_id),
    do: reserved == user_id

  def can_reclaim?(%__MODULE__{}, _), do: false

  @doc "Returns true if the seat is vacant."
  @spec vacant?(t()) :: boolean()
  def vacant?(%__MODULE__{occupant_type: :vacant}), do: true
  def vacant?(%__MODULE__{}), do: false

  @doc "Returns true if this seat belongs to the room owner."
  @spec owner?(t()) :: boolean()
  def owner?(%__MODULE__{is_owner: true}), do: true
  def owner?(%__MODULE__{}), do: false

  @doc "Returns true if any seat in the seats map is vacant."
  @spec any_vacant?(map()) :: boolean()
  def any_vacant?(seats) when is_map(seats) do
    Enum.any?(seats, fn {_pos, seat} ->
      seat.occupant_type == :vacant && seat.status == nil
    end)
  end

  @doc """
  The position `user_id` sits in, connected or not. A seat a bot plays for
  them, held for their reclaim or permanent, does not count.
  """
  @spec position_of(map(), String.t()) :: position() | nil
  def position_of(seats, user_id) when is_map(seats) do
    Enum.find_value(seats, fn {position, seat} -> if seat.user_id == user_id, do: position end)
  end

  @doc """
  Returns true if any seat in the seats map is reserved for the given user.

  Checks both:
  - Phase 1: seat in `:reconnecting` status with matching `user_id`
  - Phase 2: seat with matching `reserved_for` (`:grace` or `:bot_substitute`)
  """
  @spec reserved_for_user?(map(), String.t()) :: boolean()
  def reserved_for_user?(seats, user_id) when is_map(seats) do
    Enum.any?(seats, fn {_pos, seat} ->
      seat.reserved_for == user_id ||
        (seat.status == :reconnecting && seat.user_id == user_id)
    end)
  end

  @doc """
  Returns true if no human other than `user_id` holds a seat: everyone else at
  the table is a bot or an empty seat. A bot keeping a seat for a disconnected
  human counts as that human.
  """
  @spec alone_with_bots?(map(), String.t()) :: boolean()
  def alone_with_bots?(seats, user_id) when is_map(seats) do
    Enum.all?(seats, fn {_pos, seat} -> held_for(seat) in [nil, user_id] end)
  end

  defp held_for(%__MODULE__{occupant_type: :human, user_id: user_id}), do: user_id
  defp held_for(%__MODULE__{occupant_type: :bot, reserved_for: user_id}), do: user_id
  defp held_for(%__MODULE__{}), do: nil

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Converts a Seat to a JSON-safe map. Pids are excluded, DateTimes are
  converted to ISO 8601 strings.
  """
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = seat) do
    data = %{
      position: seat.position,
      occupant_type: seat.occupant_type,
      user_id: seat.user_id,
      status: seat.status,
      is_owner: seat.is_owner,
      substitute: seat.substitute,
      disconnected_at: maybe_to_iso8601(seat.disconnected_at),
      grace_expires_at: maybe_to_iso8601(seat.grace_expires_at),
      has_reservation: seat.reserved_for != nil,
      joined_at: maybe_to_iso8601(seat.joined_at),
      bot_persona: seat.bot_persona,
      bot_profile: public_bot_profile(seat)
    }

    if seat.occupant_type == :vacant and is_binary(seat.vacated_by),
      do: Map.put(data, :vacated_by, seat.vacated_by),
      else: data
  end

  defp public_bot_profile(%{occupant_type: :bot, bot_persona: persona}) when is_binary(persona) do
    case PidroServer.BotCatalogue.profile(persona) do
      nil -> nil
      profile -> PidroServer.BotCatalogue.public(profile)
    end
  end

  defp public_bot_profile(_seat), do: nil

  defp maybe_to_iso8601(nil), do: nil
  defp maybe_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
