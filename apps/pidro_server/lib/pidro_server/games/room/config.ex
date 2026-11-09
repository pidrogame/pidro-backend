defmodule PidroServer.Games.Room.Config do
  @moduledoc """
  The record of how a room was set up: its name, legacy bot preference,
  and whether it is a solo table.

  `bot_difficulty` is deprecated compatibility data for older clients. It is
  still validated and echoed, but every accepted value uses the same production
  rulebook. New clients should omit it.

  Seat requirements, password seats, friend holds and chosen characters stay
  in the config; holds are consumed when their user sits down or released by
  the host. A room has at most one seat password, drawn when its first seat
  needs one and kept for the life of the room, so it carries over on rematch.
  The initial bot/open plan is returned beside it because occupants change
  during play.

  There are two ways in, and both end at the same validation:

    * `new/1` - the internal constructor. Takes attributes (a keyword list or a
      map with atom or string keys) and accepts `solo` directly.
    * `parse_create_params/1` - the boundary parser. Takes a string-keyed
      create-room request body, derives `solo` from the seat plan, and rejects
      every key the grammar below does not name.

  ## Create request grammar

      body            := { name?, seats?, bot_difficulty?, rule_set? }
      name            := string, trimmed, at most 60 chars; missing or blank -> none
                         at most 4096 bytes as sent, whatever the char count
      seats           := { seat_2?, seat_3?, seat_4? }      any other key -> error "seats.<key>"
      seat            := "ai" | ai_seat | "open" | open_seat | { type: "held", user_id: uuid }
      ai_seat         := { type: "ai", persona: id }   an enabled character, once per plan
      open_seat       := { type: "open", min_games: 0 | 100 | 1000, password?: boolean }
      bot_difficulty  := "random" | "basic" | "smart"       missing -> "basic"
      rule_set        := "finnish" | "louisiana"             missing -> "finnish"

      solo            := seat_2 = seat_3 = seat_4 = "ai"
      seat_plan       := { east <- seat_2, south <- seat_3, west <- seat_4 }

  ## Errors

  Both entry points collect every problem rather than stopping at the first and
  return `{:error, {:invalid_room_params, errors}}`, where each error is
  `%{field: path, message: text}` and `path` names the offending field, such as
  `"settings"`, `"bot_difficulty"` or `"seats.seat_5"`. A seat naming a
  character nobody can choose, or one already in the plan, also carries `code`,
  `"UNKNOWN_PERSONA"` or `"PERSONA_SEATED"`. Caller input is never converted to
  an atom.

  This module reads no application config, no repo and no process; it checks a
  chosen character against the bot catalogue's snapshot. The only other impure
  step is drawing a seat password from `:crypto`.
  """

  @type bot_difficulty :: :random | :basic | :smart
  @type seat_plan :: %{
          east: :bot | :open | :held,
          south: :bot | :open | :held,
          west: :bot | :open | :held
        }
  @type seat_entry ::
          :bot | {:bot, String.t()} | {:open, 0 | 100 | 1000, boolean()} | {:held, Ecto.UUID.t()}
  @type error :: %{
          required(:field) => String.t(),
          required(:message) => String.t(),
          optional(:code) => String.t()
        }
  @type errors :: {:invalid_room_params, [error()]}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          bot_difficulty: bot_difficulty(),
          rule_set: :finnish | :louisiana,
          solo: boolean(),
          seat_requirements: %{optional(atom()) => 0 | 100 | 1000},
          seat_holds: %{optional(atom()) => Ecto.UUID.t()},
          seat_personas: %{optional(atom()) => String.t()},
          password_seats: [atom()],
          seat_password: String.t() | nil
        }

  # The seat password must never reach a log, crash report included.
  @derive {Inspect, except: [:seat_password]}
  defstruct name: nil,
            bot_difficulty: :basic,
            rule_set: :finnish,
            solo: false,
            seat_requirements: %{},
            seat_holds: %{},
            seat_personas: %{},
            password_seats: [],
            seat_password: nil

  @max_name_length 60

  # A character is a grapheme, and one grapheme can carry any number of
  # combining marks, so the character cap alone does not bound a name's size.
  # The longest emoji sequence Unicode recommends is 35 bytes, which puts 60 of
  # them at 2100 bytes; 4096 leaves every real name alone and is checked on the
  # raw input, before anything walks the string.
  @max_name_bytes 4096

  @difficulties [:random, :basic, :smart]
  @difficulty_by_wire %{"random" => :random, "basic" => :basic, "smart" => :smart}
  @difficulty_wire_values Enum.map(@difficulties, &Atom.to_string/1)

  # Validation and error order for the config's own fields.
  @fields [
    :name,
    :bot_difficulty,
    :rule_set,
    :solo,
    :seat_requirements,
    :seat_holds,
    :seat_personas,
    :password_seats,
    :seat_password
  ]
  @field_by_wire %{
    "name" => :name,
    "bot_difficulty" => :bot_difficulty,
    "rule_set" => :rule_set,
    "solo" => :solo,
    "seat_requirements" => :seat_requirements,
    "seat_holds" => :seat_holds,
    "seat_personas" => :seat_personas,
    "password_seats" => :password_seats,
    "seat_password" => :seat_password
  }
  @rule_set_by_wire %{"finnish" => :finnish, "louisiana" => :louisiana}

  # `ads_aware` is no room setting: a client that knows about ads says so, and
  # the room controller holds only that client to the ad schedule (PID-123).
  @accepted_fields ["name", "seats", "bot_difficulty", "rule_set", "ads_aware"]

  # Seat order for the plan and for seat errors.
  @seats [{"seat_2", :east}, {"seat_3", :south}, {"seat_4", :west}]
  @seat_keys Enum.map(@seats, &elem(&1, 0))

  # What a seat may be asked to hold, in the order the error message lists them.
  @seat_occupants [{"ai", :bot}, {"open", :open}]
  @seat_values Enum.map(@seat_occupants, &elem(&1, 0))
  @open_seat_message "must be an open seat with min_games of 0, 100 or 1000 and a boolean password"

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc "Returns the default config: no name, `:basic` difficulty, Finnish rules, not solo."
  @spec new() :: {:ok, t()}
  def new, do: {:ok, %__MODULE__{}}

  @doc """
  Builds a config from attributes.

  Accepts a keyword list or a map with atom or string keys, or an existing
  config, which is validated and returned. The recognised keys are `name`,
  `bot_difficulty` and `rule_set` (atoms or wire strings), `solo`, and
  `seat_requirements` (position atoms mapped to 0, 100 or 1000). A missing key
  takes its default. Any other key is rejected, as is a key given more than once.

  ## Examples

      iex> PidroServer.Games.Room.Config.new(name: " Friday ", bot_difficulty: "smart")
      {:ok, %PidroServer.Games.Room.Config{name: "Friday", bot_difficulty: :smart, solo: false}}

      iex> PidroServer.Games.Room.Config.new(is_dev_room: true)
      {:error, {:invalid_room_params, [%{field: "is_dev_room", message: "is not an accepted field"}]}}
  """
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, errors()}
  def new(%__MODULE__{} = config), do: config |> Map.from_struct() |> build()
  def new(attrs) when is_map(attrs) and not is_struct(attrs), do: build(attrs)

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: build(attrs), else: invalid_attrs()
  end

  def new(_attrs), do: invalid_attrs()

  # ---------------------------------------------------------------------------
  # Boundary Parser
  # ---------------------------------------------------------------------------

  @doc """
  Parses a string-keyed create-room request body into a config and a seat plan.

  `solo` is derived here, once: it is true when seats 2, 3 and 4 are all `"ai"`.
  The name and difficulty then go through the same validation as `new/1`.

  Errors are ordered: `name`, then `seats` (known seats in seat order, then
  unknown seat keys sorted), then `bot_difficulty`, then `rule_set`, then `ads_aware`, then
  unknown top-level keys sorted.

  ## Examples

      iex> PidroServer.Games.Room.Config.parse_create_params(%{"seats" => %{"seat_3" => "ai"}})
      {:ok, %PidroServer.Games.Room.Config{}, %{east: :open, south: :bot, west: :open}}

      iex> PidroServer.Games.Room.Config.parse_create_params(%{"settings" => %{}})
      {:error, {:invalid_room_params, [%{field: "settings", message: "is not an accepted field"}]}}
  """
  @spec parse_create_params(term()) :: {:ok, t(), seat_plan()} | {:error, errors()}
  def parse_create_params(body) when is_map(body) and not is_struct(body) do
    {seat_plan, requirements, holds, personas, password_seats, seat_errors} = parse_seats(body)
    unknown_errors = unknown_key_errors(Map.keys(body), @accepted_fields, "", &body_label/1)

    {config, config_errors} =
      body
      |> Map.take(["name", "bot_difficulty", "rule_set"])
      |> Map.put("solo", solo_plan?(seat_plan))
      |> Map.put("seat_requirements", requirements)
      |> Map.put("seat_holds", holds)
      |> Map.put("seat_personas", personas)
      |> Map.put("password_seats", password_seats)
      |> build()
      |> split_result()

    {name_errors, difficulty_errors} = Enum.split_with(config_errors, &(&1.field == "name"))

    ads_errors =
      if is_boolean(Map.get(body, "ads_aware", false)),
        do: [],
        else: [error("ads_aware", "must be a boolean")]

    case name_errors ++ seat_errors ++ difficulty_errors ++ ads_errors ++ unknown_errors do
      [] -> {:ok, config, seat_plan}
      errors -> {:error, {:invalid_room_params, errors}}
    end
  end

  def parse_create_params(_body) do
    {:error, {:invalid_room_params, [error("body", "must be a JSON object")]}}
  end

  @doc """
  Returns the top-level field names a create-room request may contain.

  The OpenAPI create-request schema is checked against this list so the two
  descriptions cannot drift apart.
  """
  @spec accepted_fields() :: [String.t()]
  def accepted_fields, do: @accepted_fields

  @doc """
  Returns the accepted `bot_difficulty` wire strings, in declared order.

  Like the three functions below, this is a value constraint of the create
  request. The OpenAPI room schemas take their enums and name cap from these
  functions, and a spec test checks the published spec against them.
  """
  @spec difficulties() :: [String.t()]
  def difficulties, do: @difficulty_wire_values

  @doc "Returns the accepted rule-set wire strings."
  @spec rule_sets() :: [String.t()]
  def rule_sets, do: ["finnish", "louisiana"]

  @doc "Returns the keys a create request's `seats` object may contain, in seat order."
  @spec seat_keys() :: [String.t()]
  def seat_keys, do: @seat_keys

  @doc "Returns the values a create request may give a seat."
  @spec seat_values() :: [String.t()]
  def seat_values, do: @seat_values

  @doc "Returns the most characters a room name may have after trimming."
  @spec max_name_length() :: pos_integer()
  def max_name_length, do: @max_name_length

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Converts a config to a JSON-safe map. Difficulty and rule set are emitted as wire strings.
  """
  @spec serialize(t()) :: %{
          name: String.t() | nil,
          bot_difficulty: String.t(),
          rule_set: String.t(),
          solo: boolean()
        }
  def serialize(%__MODULE__{} = config) do
    %{
      name: config.name,
      bot_difficulty: Atom.to_string(config.bot_difficulty),
      rule_set: Atom.to_string(config.rule_set),
      solo: config.solo
    }
  end

  @doc "Serializes a seat with its configured requirement; occupied seats show zero."
  @spec serialize_seat(t(), PidroServer.Games.Room.Seat.t()) :: map()
  def serialize_seat(%__MODULE__{} = config, seat) do
    held_user_id = if seat.occupant_type == :vacant, do: config.seat_holds[seat.position]

    min_games =
      if seat.occupant_type == :vacant and is_nil(held_user_id),
        do: Map.get(config.seat_requirements, seat.position, 0),
        else: 0

    password? =
      seat.occupant_type == :vacant and is_nil(held_user_id) and
        seat.position in config.password_seats

    data =
      seat
      |> PidroServer.Games.Room.Seat.serialize()
      |> Map.merge(%{min_games: min_games, password: password?})

    if held_user_id,
      do: Map.merge(data, %{status: "free", held_for: %{user_id: held_user_id}}),
      else: data
  end

  # ---------------------------------------------------------------------------
  # Seat Changes
  # ---------------------------------------------------------------------------

  @doc """
  Parses one seat of an existing room as the seat picker sends it: any value a
  create request's seat takes.

      iex> PidroServer.Games.Room.Config.parse_seat_entry(%{"type" => "open", "min_games" => 100})
      {:ok, {:open, 100, false}}
  """
  @spec parse_seat_entry(term()) :: {:ok, seat_entry()} | {:error, errors()}
  def parse_seat_entry(value) do
    case parse_seat(%{"seat" => value}, "seat") do
      {:ok, :bot, nil} -> {:ok, :bot}
      {:ok, :bot, persona} -> {:ok, {:bot, persona}}
      {:ok, :open, {games, password?}} -> {:ok, {:open, games, password?}}
      {:ok, :held, user_id} -> {:ok, {:held, user_id}}
      {:error, reason} -> {:error, {:invalid_room_params, [seat_error("seat", reason)]}}
    end
  end

  @doc """
  Makes `position` the seat `entry` asks for. Whatever the config said about the
  seat before, a requirement, a password, a hold or a character, goes. A
  character chosen here leaves any other seat they were chosen for.
  """
  @spec put_seat(t(), atom(), seat_entry()) :: t()
  def put_seat(%__MODULE__{} = config, position, entry) do
    config = %{
      config
      | seat_requirements: Map.delete(config.seat_requirements, position),
        seat_holds: Map.delete(config.seat_holds, position),
        seat_personas: Map.delete(config.seat_personas, position)
    }

    case entry do
      {:open, 0, password?} ->
        put_password_seat(config, position, password?)

      {:open, games, password?} ->
        requirements = Map.put(config.seat_requirements, position, games)
        put_password_seat(%{config | seat_requirements: requirements}, position, password?)

      {:held, user_id} ->
        holds = Map.put(config.seat_holds, position, user_id)
        put_password_seat(%{config | seat_holds: holds}, position, false)

      {:bot, persona} ->
        personas =
          for {seat, chosen} <- config.seat_personas,
              chosen != persona,
              into: %{},
              do: {seat, chosen}

        put_password_seat(
          %{config | seat_personas: Map.put(personas, position, persona)},
          position,
          false
        )

      :bot ->
        put_password_seat(config, position, false)
    end
  end

  # ---------------------------------------------------------------------------
  # Seat Passwords
  # ---------------------------------------------------------------------------

  @doc """
  Makes `position` a password seat, or an ordinary one again.

  The first password seat draws the room's password; later seats share it, and
  clearing every password seat keeps it, so the host never has to read out a
  second one.
  """
  @spec put_password_seat(t(), atom(), boolean()) :: t()
  def put_password_seat(%__MODULE__{} = config, position, true) do
    %{
      config
      | password_seats: Enum.sort(Enum.uniq([position | config.password_seats])),
        seat_password: config.seat_password || generate_password()
    }
  end

  def put_password_seat(%__MODULE__{} = config, position, false),
    do: %{config | password_seats: List.delete(config.password_seats, position)}

  @doc """
  Checks the password for sitting at `position`. A seat without a password, or
  one held for `user_id`, needs none.
  """
  @spec check_password(t(), atom(), String.t(), term()) :: :ok | {:error, :seat_requires_password}
  def check_password(%__MODULE__{} = config, position, user_id, password) do
    cond do
      position not in config.password_seats -> :ok
      config.seat_holds[position] == user_id -> :ok
      is_binary(password) and Plug.Crypto.secure_compare(password, config.seat_password) -> :ok
      true -> {:error, :seat_requires_password}
    end
  end

  @doc """
  Draws a four-digit seat password that is easy to read out but not to guess:
  at least three different digits and no straight run like 1234 or 4321.
  """
  @spec generate_password() :: String.t()
  def generate_password do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    password = n |> rem(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")
    if easy_password?(password), do: generate_password(), else: password
  end

  @doc "True for a four-digit password a person would guess first."
  @spec easy_password?(String.t()) :: boolean()
  def easy_password?(<<_::binary-size(4)>> = password) do
    digits = for <<d <- password>>, do: d - ?0
    steps = digits |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    not Enum.all?(digits, &(&1 in 0..9)) or length(Enum.uniq(digits)) < 3 or
      steps in [[1, 1, 1], [-1, -1, -1]]
  end

  def easy_password?(_password), do: true

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  # The one validation both entry points end at. `attrs` is any enumerable of
  # `{key, value}` pairs.
  defp build(attrs) do
    {known, duplicates, unknown} = classify(attrs)
    defaults = %__MODULE__{}

    results =
      Enum.map(@fields, fn field ->
        cond do
          field in duplicates -> {field, {:error, "was given more than once"}}
          Map.has_key?(known, field) -> {field, validate(field, Map.fetch!(known, field))}
          true -> {field, {:ok, Map.fetch!(defaults, field)}}
        end
      end)

    field_errors =
      for {field, {:error, message}} <- results, do: error(Atom.to_string(field), message)

    case field_errors ++ unknown_key_errors(unknown, [], "", &attr_label/1) do
      [] ->
        config = struct!(__MODULE__, for({field, {:ok, value}} <- results, do: {field, value}))
        {:ok, Enum.reduce(config.password_seats, config, &put_password_seat(&2, &1, true))}

      errors ->
        {:error, {:invalid_room_params, errors}}
    end
  end

  # Sorts attribute keys into recognised fields, fields given twice (as an atom
  # and a string, or repeated in a keyword list), and everything else.
  defp classify(attrs) do
    Enum.reduce(attrs, {%{}, [], []}, fn {key, value}, {known, duplicates, unknown} ->
      case field_for(key) do
        nil ->
          {known, duplicates, [key | unknown]}

        field when is_map_key(known, field) ->
          {known, Enum.uniq([field | duplicates]), unknown}

        field ->
          {Map.put(known, field, value), duplicates, unknown}
      end
    end)
  end

  defp field_for(key) when key in @fields, do: key
  defp field_for(key) when is_binary(key), do: Map.get(@field_by_wire, key)
  defp field_for(_key), do: nil

  defp validate(:name, nil), do: {:ok, nil}

  defp validate(:name, name) when is_binary(name) and byte_size(name) > @max_name_bytes,
    do: {:error, name_length_message()}

  defp validate(:name, name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > @max_name_length -> {:error, name_length_message()}
      true -> {:ok, trimmed}
    end
  end

  defp validate(:name, _other), do: {:error, "must be a string"}

  defp validate(:bot_difficulty, difficulty) when difficulty in @difficulties,
    do: {:ok, difficulty}

  defp validate(:bot_difficulty, difficulty) do
    # An explicit lookup: caller input is never turned into an atom.
    case Map.fetch(@difficulty_by_wire, difficulty) do
      {:ok, known} -> {:ok, known}
      :error -> {:error, "must be one of: #{Enum.join(@difficulty_wire_values, ", ")}"}
    end
  end

  defp validate(:solo, solo) when is_boolean(solo), do: {:ok, solo}
  defp validate(:solo, _other), do: {:error, "must be a boolean"}

  defp validate(:seat_requirements, requirements) when is_map(requirements) do
    if Enum.all?(requirements, fn {position, games} ->
         position in [:east, :south, :west] and games in [0, 100, 1000]
       end),
       do: {:ok, requirements},
       else: {:error, "must map east, south or west to 0, 100 or 1000"}
  end

  defp validate(:seat_requirements, _), do: {:error, "must be a map"}

  defp validate(:seat_holds, holds) when is_map(holds) do
    if Enum.all?(holds, fn {position, user_id} ->
         position in [:north, :east, :south, :west] and
           match?({:ok, ^user_id}, Ecto.UUID.cast(user_id))
       end),
       do: {:ok, holds},
       else: {:error, "must map positions to user UUIDs"}
  end

  defp validate(:seat_holds, _), do: {:error, "must be a map"}

  defp validate(:seat_personas, personas) when is_map(personas) do
    if Enum.all?(personas, fn {position, persona} ->
         position in [:north, :east, :south, :west] and is_binary(persona)
       end),
       do: {:ok, personas},
       else: {:error, "must map positions to character ids"}
  end

  defp validate(:seat_personas, _), do: {:error, "must be a map"}

  defp validate(:password_seats, positions) when is_list(positions) do
    if Enum.all?(positions, &(&1 in [:north, :east, :south, :west])),
      do: {:ok, positions |> Enum.uniq() |> Enum.sort()},
      else: {:error, "must list north, east, south or west"}
  end

  defp validate(:password_seats, _), do: {:error, "must be a list"}

  defp validate(:seat_password, nil), do: {:ok, nil}

  defp validate(:seat_password, password) do
    if easy_password?(password),
      do: {:error, "must be four digits without an easy pattern"},
      else: {:ok, password}
  end

  defp validate(:rule_set, value) when value in [:finnish, :louisiana], do: {:ok, value}

  defp validate(:rule_set, value) do
    case Map.fetch(@rule_set_by_wire, value) do
      {:ok, known} -> {:ok, known}
      :error -> {:error, "must be one of: #{Enum.join(rule_sets(), ", ")}"}
    end
  end

  defp name_length_message, do: "must be at most #{@max_name_length} characters"

  # ---------------------------------------------------------------------------
  # Seat Plan
  # ---------------------------------------------------------------------------

  defp parse_seats(body) do
    case Map.fetch(body, "seats") do
      :error ->
        {open_plan(), %{}, %{}, %{}, [], []}

      {:ok, seats} when is_map(seats) and not is_struct(seats) ->
        # A character chosen for an earlier seat is already at the table.
        {results, _chosen} =
          Enum.map_reduce(@seats, [], fn {key, position}, chosen ->
            case parse_seat(seats, key) do
              {:ok, :bot, persona} = result when is_binary(persona) ->
                if persona in chosen,
                  do:
                    {{key, position, {:error, {"PERSONA_SEATED", "is already at this table"}}},
                     chosen},
                  else: {{key, position, result}, [persona | chosen]}

              result ->
                {{key, position, result}, chosen}
            end
          end)

        plan =
          Map.new(results, fn
            {_key, position, {:ok, occupant, _min_games}} -> {position, occupant}
            {_key, position, {:error, _message}} -> {position, :open}
          end)

        requirements =
          for {_key, position, {:ok, :open, {min_games, _password?}}} <- results,
              min_games > 0,
              into: %{},
              do: {position, min_games}

        holds =
          for {_key, position, {:ok, :held, user_id}} <- results,
              into: %{},
              do: {position, user_id}

        personas =
          for {_key, position, {:ok, :bot, persona}} <- results,
              is_binary(persona),
              into: %{},
              do: {position, persona}

        password_seats =
          for {_key, position, {:ok, :open, {_min_games, true}}} <- results, do: position

        value_errors =
          for {key, _position, {:error, reason}} <- results,
              do: seat_error("seats." <> key, reason)

        {plan, requirements, holds, personas, password_seats,
         value_errors ++ unknown_key_errors(Map.keys(seats), @seat_keys, "seats.", &body_label/1)}

      {:ok, _other} ->
        {open_plan(), %{}, %{}, %{}, [], [error("seats", "must be an object")]}
    end
  end

  defp parse_seat(seats, key) do
    case Map.get(seats, key, "open") do
      "ai" ->
        {:ok, :bot, nil}

      %{"type" => "ai", "persona" => persona} = value when map_size(value) == 2 ->
        if persona in PidroServer.Games.Room.Seat.bot_personas(),
          do: {:ok, :bot, persona},
          else: {:error, {"UNKNOWN_PERSONA", "must be a character who plays at tables"}}

      "open" ->
        {:ok, :open, {0, false}}

      %{"type" => "open"} = value ->
        parse_open_seat(value)

      %{"type" => "held", "user_id" => user_id} = value when map_size(value) == 2 ->
        case Ecto.UUID.cast(user_id) do
          {:ok, id} -> {:ok, :held, id}
          :error -> {:error, "held seats require a user_id UUID"}
        end

      value when is_map(value) ->
        {:error, @open_seat_message}

      _ ->
        {:error, "must be one of: #{Enum.join(@seat_values, ", ")}"}
    end
  end

  defp parse_open_seat(value) do
    games = Map.get(value, "min_games")
    password? = Map.get(value, "password", false)

    if games in [0, 100, 1000] and is_boolean(password?) and
         Enum.all?(Map.keys(value), &(&1 in ["type", "min_games", "password"])),
       do: {:ok, :open, {games, password?}},
       else: {:error, @open_seat_message}
  end

  defp open_plan, do: Map.new(@seats, fn {_key, position} -> {position, :open} end)

  defp solo_plan?(seat_plan), do: Enum.all?(seat_plan, fn {_position, seat} -> seat == :bot end)

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  defp unknown_key_errors(keys, accepted, prefix, label) do
    keys
    |> Enum.reject(&(&1 in accepted))
    |> Enum.map(label)
    |> Enum.sort()
    |> Enum.map(&error(prefix <> &1, "is not an accepted field"))
  end

  # Path segments for unknown keys. Neither ever mints an atom from a key.
  # Internal attributes may be atom-keyed, so `:is_dev_room` reads "is_dev_room".
  defp attr_label(key) when is_atom(key), do: Atom.to_string(key)
  defp attr_label(key), do: body_label(key)

  # A request body is string-keyed, so any other key shows as written: ":name".
  defp body_label(key) when is_binary(key), do: key
  defp body_label(key), do: inspect(key)

  defp split_result({:ok, config}), do: {config, []}
  defp split_result({:error, {:invalid_room_params, errors}}), do: {nil, errors}

  defp invalid_attrs do
    {:error,
     {:invalid_room_params, [error("config", "must be a map, a keyword list or a config")]}}
  end

  defp error(field, message), do: %{field: field, message: message}

  defp seat_error(field, {code, message}), do: Map.put(error(field, message), :code, code)
  defp seat_error(field, message), do: error(field, message)
end
