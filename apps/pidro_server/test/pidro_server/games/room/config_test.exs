defmodule PidroServer.Games.Room.ConfigTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Room.Config

  doctest Config

  @all_open %{east: :open, south: :open, west: :open}

  test "open-seat requirements parse, persist and serialize only on vacant seats" do
    alias PidroServer.Games.Room.Seat

    for games <- [0, 100, 1000] do
      body = %{"seats" => %{"seat_3" => %{"type" => "open", "min_games" => games}}}
      assert {:ok, config, @all_open} = Config.parse_create_params(body)
      assert {:ok, ^config} = Config.new(config)
      assert Config.serialize_seat(config, Seat.new_vacant(:south)).min_games == games
      assert Config.serialize_seat(config, Seat.new_vacant(:east)).min_games == 0
      assert Config.serialize_seat(config, Seat.new_human(:south, "player")).min_games == 0
      assert Config.serialize_seat(config, Seat.new_bot(:south, self())).min_games == 0
    end

    for invalid <-
          [
            %{"min_games" => 100},
            %{"type" => "open"},
            %{"type" => "ai", "min_games" => 100},
            %{"type" => "open", "min_games" => 100, "extra" => true}
          ] ++
            Enum.map(
              [-1, 1, 101, 100.0, "100", nil, true],
              &%{"type" => "open", "min_games" => &1}
            ) do
      assert {:error, {:invalid_room_params, [%{field: "seats.seat_3"}]}} =
               Config.parse_create_params(%{"seats" => %{"seat_3" => invalid}})
    end
  end

  describe "seat passwords" do
    alias PidroServer.Games.Room.Seat

    test "generated passwords are four digits without an easy pattern" do
      passwords = for _ <- 1..2_000, do: Config.generate_password()

      assert Enum.all?(passwords, &(&1 =~ ~r/\A\d{4}\z/))
      refute Enum.any?(passwords, &Config.easy_password?/1)
      assert length(Enum.uniq(passwords)) > 1_000
    end

    test "repeats, pairs and straight runs are easy; three different digits are not" do
      for easy <- ~w(0000 1111 1112 1212 1122 0123 1234 6789 4321 9876 3210 123 12345 12a4) do
        assert Config.easy_password?(easy), easy
      end

      for fine <- ~w(4821 0472 1243 9870 1235 5431 0129) do
        refute Config.easy_password?(fine), fine
      end
    end

    test "a create body marks password seats, draws one password and keeps min_games" do
      body = %{
        "seats" => %{
          "seat_2" => %{"type" => "open", "min_games" => 100, "password" => true},
          "seat_3" => %{"type" => "open", "min_games" => 0, "password" => true},
          "seat_4" => %{"type" => "open", "min_games" => 0, "password" => false}
        }
      }

      assert {:ok, config, @all_open} = Config.parse_create_params(body)
      assert config.password_seats == [:east, :south]
      assert config.seat_requirements == %{east: 100}
      refute Config.easy_password?(config.seat_password)
      assert {:ok, ^config} = Config.new(config)

      assert Config.serialize_seat(config, Seat.new_vacant(:south)).password
      refute Config.serialize_seat(config, Seat.new_vacant(:west)).password
      refute Config.serialize_seat(config, Seat.new_human(:south, "player")).password
      refute Map.has_key?(Config.serialize(config), :seat_password)
      refute inspect(config) =~ "seat_password"

      for invalid <- [nil, "yes", 1] do
        seat = %{"type" => "open", "min_games" => 0, "password" => invalid}

        assert {:error, {:invalid_room_params, [%{field: "seats.seat_3"}]}} =
                 Config.parse_create_params(%{"seats" => %{"seat_3" => seat}})
      end

      assert {:ok, %Config{password_seats: [], seat_password: nil}, _} =
               Config.parse_create_params(%{"seats" => %{"seat_3" => "open"}})
    end

    test "every password seat shares the first password, and it outlives them" do
      config = Config.put_password_seat(%Config{}, :east, true)
      password = config.seat_password

      config = Config.put_password_seat(config, :west, true)
      assert {config.password_seats, config.seat_password} == {[:east, :west], password}

      config =
        config |> Config.put_password_seat(:east, false) |> Config.put_password_seat(:west, false)

      assert {config.password_seats, config.seat_password} == {[], password}
      assert Config.put_password_seat(config, :south, true).seat_password == password
    end

    test "the password is checked only on password seats, and never for their held user" do
      config = %{
        Config.put_password_seat(%Config{}, :south, true)
        | seat_holds: %{west: "friend"}
      }

      config = Config.put_password_seat(config, :west, true)

      assert Config.check_password(config, :south, "player", config.seat_password) == :ok
      assert Config.check_password(config, :east, "player", nil) == :ok
      assert Config.check_password(config, :west, "friend", nil) == :ok

      for wrong <- [nil, "", "0000", String.to_integer(config.seat_password)] do
        assert Config.check_password(config, :south, "player", wrong) ==
                 {:error, :seat_requires_password}
      end

      assert Config.check_password(config, :west, "player", nil) ==
               {:error, :seat_requires_password}
    end

    test "new/1 refuses an easy password" do
      assert {:error, {:invalid_room_params, [%{field: "seat_password"}]}} =
               Config.new(password_seats: [:south], seat_password: "1234")
    end
  end

  test "game-state bid schemas accept both variants' boundaries" do
    alias PidroServerWeb.Schemas.RoomSchemas.{Bid, GameStateResponse}

    highest =
      GameStateResponse.schema().properties.data.properties.state.properties.highest_bid

    for schema <- [Bid.schema().properties.amount, highest.properties.amount] do
      for amount <- [6, 7, 14],
          do: assert({:ok, ^amount} = OpenApiSpex.cast_value(amount, schema))

      for amount <- [5, 15], do: assert({:error, _} = OpenApiSpex.cast_value(amount, schema))
    end
  end

  test "rule sets default to Finnish, validate without atom conversion, and serialize" do
    assert {:ok, %Config{rule_set: :finnish}, @all_open} = Config.parse_create_params(%{})

    for {wire, atom} <- [{"finnish", :finnish}, {"louisiana", :louisiana}] do
      assert {:ok, config, @all_open} = Config.parse_create_params(%{"rule_set" => wire})
      assert config.rule_set == atom
      assert Config.serialize(config).rule_set == wire
      assert Config.new(rule_set: atom) == {:ok, config}
    end

    garbage = "unknown_rules_#{System.unique_integer([:positive])}"

    for invalid <- [garbage, nil, 7, "Louisiana"] do
      assert {:error, {:invalid_room_params, [%{field: "rule_set"}]}} =
               Config.parse_create_params(%{"rule_set" => invalid})
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(garbage) end

    for module <- [
          PidroServerWeb.Schemas.RoomSchemas.RoomConfig,
          PidroServerWeb.Schemas.RoomSchemas.RoomCreateRequest
        ] do
      schema = module.schema()
      assert schema.properties.rule_set.enum == Config.rule_sets()
      assert schema.properties.rule_set.default == "finnish"
    end
  end

  defp fields({:error, {:invalid_room_params, errors}}), do: Enum.map(errors, & &1.field)

  describe "default config" do
    test "new/0 returns no name, basic difficulty, not solo" do
      assert {:ok, %Config{name: nil, bot_difficulty: :basic, solo: false}} = Config.new()
    end

    test "new/1 with an empty map or keyword list equals the default" do
      {:ok, default} = Config.new()

      assert Config.new(%{}) == {:ok, default}
      assert Config.new([]) == {:ok, default}
    end

    test "the bare struct equals the default" do
      assert {:ok, %Config{}} == Config.new()
    end
  end

  describe "new/1 accepted attributes" do
    test "accepts a keyword list with atom keys" do
      assert {:ok, %Config{name: "Friday", bot_difficulty: :smart, solo: false}} =
               Config.new(name: "Friday", bot_difficulty: :smart)
    end

    test "accepts a map with atom keys" do
      assert {:ok, %Config{name: "Friday", bot_difficulty: :random, solo: true}} =
               Config.new(%{name: "Friday", bot_difficulty: :random, solo: true})
    end

    test "accepts a map with string keys" do
      assert {:ok, %Config{name: "Friday", bot_difficulty: :smart, solo: true}} =
               Config.new(%{"name" => "Friday", "bot_difficulty" => "smart", "solo" => true})
    end

    test "accepts solo: true with no seat plan" do
      assert {:ok, %Config{solo: true}} = Config.new(solo: true)
    end

    test "accepts the difficulty as a wire string or an atom alike" do
      assert Config.new(bot_difficulty: "random") == Config.new(bot_difficulty: :random)
      assert {:ok, %Config{bot_difficulty: :random}} = Config.new(bot_difficulty: "random")
      assert {:ok, %Config{bot_difficulty: :basic}} = Config.new(bot_difficulty: "basic")
      assert {:ok, %Config{bot_difficulty: :smart}} = Config.new(bot_difficulty: :smart)
    end

    test "returns an existing config unchanged" do
      {:ok, config} = Config.new(name: "Friday", bot_difficulty: :smart, solo: true)

      assert Config.new(config) == {:ok, config}
    end

    test "treats a nil name as no name" do
      assert {:ok, %Config{name: nil}} = Config.new(name: nil)
    end

    test "round-trips a serialized config" do
      {:ok, config} = Config.new(name: "Friday", bot_difficulty: :smart, solo: true)

      assert Config.new(Config.serialize(config)) == {:ok, config}
    end
  end

  describe "new/1 rejected attributes" do
    test "rejects is_dev_room as an unknown key" do
      assert {:error, {:invalid_room_params, [%{field: "is_dev_room", message: message}]}} =
               Config.new(%{is_dev_room: true})

      assert is_binary(message)
    end

    test "rejects an unknown string key without minting an atom" do
      key = "zz_room_config_never_an_atom_#{System.unique_integer([:positive])}"

      assert fields(Config.new(%{key => 1})) == [key]
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "rejects an unknown difficulty, as atom or string" do
      assert fields(Config.new(bot_difficulty: :expert)) == ["bot_difficulty"]
      assert fields(Config.new(bot_difficulty: "expert")) == ["bot_difficulty"]
      assert fields(Config.new(bot_difficulty: nil)) == ["bot_difficulty"]
      assert fields(Config.new(bot_difficulty: 3)) == ["bot_difficulty"]
    end

    test "rejects a non-boolean solo" do
      assert fields(Config.new(solo: "true")) == ["solo"]
      assert fields(Config.new(solo: nil)) == ["solo"]
    end

    test "rejects a non-string and an over-long name" do
      assert fields(Config.new(name: 42)) == ["name"]
      assert fields(Config.new(name: String.duplicate("a", 61))) == ["name"]
    end

    test "rejects a key given as both an atom and a string" do
      assert fields(Config.new(%{:name => "A", "name" => "B"})) == ["name"]
    end

    test "rejects attributes that are neither a map, a keyword list nor a config" do
      assert {:error, {:invalid_room_params, [%{field: "config", message: _}]}} =
               Config.new("Friday")

      assert {:error, {:invalid_room_params, [%{field: "config", message: _}]}} =
               Config.new([1, 2])

      assert {:error, {:invalid_room_params, [%{field: "config", message: _}]}} = Config.new(nil)
    end

    test "collects every error" do
      result = Config.new(name: 42, bot_difficulty: :expert, solo: 1, is_dev_room: true)

      assert fields(result) == ["name", "bot_difficulty", "solo", "is_dev_room"]
    end
  end

  describe "parse_create_params/1 happy paths" do
    test "an empty body parses to the default config with all seats open" do
      {:ok, default} = Config.new()

      assert Config.parse_create_params(%{}) == {:ok, default, @all_open}
    end

    test "a name, one ai seat and smart" do
      body = %{"name" => "Friday", "seats" => %{"seat_3" => "ai"}, "bot_difficulty" => "smart"}

      assert {:ok, config, seat_plan} = Config.parse_create_params(body)
      assert config == %Config{name: "Friday", bot_difficulty: :smart, solo: false}
      assert seat_plan == %{east: :open, south: :bot, west: :open}
    end

    test "maps seat_2 to east, seat_3 to south and seat_4 to west" do
      assert {:ok, _, %{east: :bot, south: :open, west: :open}} =
               Config.parse_create_params(%{"seats" => %{"seat_2" => "ai"}})

      assert {:ok, _, %{east: :open, south: :bot, west: :open}} =
               Config.parse_create_params(%{"seats" => %{"seat_3" => "ai"}})

      assert {:ok, _, %{east: :open, south: :open, west: :bot}} =
               Config.parse_create_params(%{"seats" => %{"seat_4" => "ai"}})
    end

    test "seats 2, 3 and 4 all ai parse to a solo config" do
      body = %{"seats" => %{"seat_2" => "ai", "seat_3" => "ai", "seat_4" => "ai"}}

      assert {:ok, %Config{solo: true, bot_difficulty: :basic}, seat_plan} =
               Config.parse_create_params(body)

      assert seat_plan == %{east: :bot, south: :bot, west: :bot}
    end

    test "two ai seats and one missing seat key parse to not solo with the missing seat open" do
      body = %{"seats" => %{"seat_2" => "ai", "seat_4" => "ai"}}

      assert {:ok, %Config{solo: false}, seat_plan} = Config.parse_create_params(body)
      assert seat_plan == %{east: :bot, south: :open, west: :bot}
    end

    test "explicit open seats and an empty seats object are all open" do
      explicit = %{"seats" => %{"seat_2" => "open", "seat_3" => "open", "seat_4" => "open"}}

      assert {:ok, %Config{solo: false}, @all_open} = Config.parse_create_params(explicit)

      assert {:ok, %Config{solo: false}, @all_open} =
               Config.parse_create_params(%{"seats" => %{}})
    end

    test "an omitted difficulty yields basic" do
      body = %{"seats" => %{"seat_2" => "ai"}}

      assert {:ok, %Config{bot_difficulty: :basic}, _} = Config.parse_create_params(body)
    end

    test "a difficulty supplied with no bot seat is accepted and stored" do
      assert {:ok, %Config{bot_difficulty: :random, solo: false}, @all_open} =
               Config.parse_create_params(%{"bot_difficulty" => "random"})
    end
  end

  describe "parse_create_params/1 name" do
    test "a name of only whitespace is stored as none" do
      assert {:ok, %Config{name: nil}, _} = Config.parse_create_params(%{"name" => "  \t\n "})
      assert {:ok, %Config{name: nil}, _} = Config.parse_create_params(%{"name" => ""})
    end

    test "a null name is stored as none" do
      assert {:ok, %Config{name: nil}, _} = Config.parse_create_params(%{"name" => nil})
    end

    test "a name with surrounding spaces is stored trimmed" do
      assert {:ok, %Config{name: "Friday night"}, _} =
               Config.parse_create_params(%{"name" => "  Friday night  "})
    end

    test "a 60-character name is accepted" do
      name = String.duplicate("a", 60)

      assert {:ok, %Config{name: ^name}, _} = Config.parse_create_params(%{"name" => name})
    end

    test "the cap counts characters, not bytes, and applies after trimming" do
      name = String.duplicate("å", 60)

      assert {:ok, %Config{name: ^name}, _} =
               Config.parse_create_params(%{"name" => "  " <> name <> "  "})
    end

    test "a 61-character name is rejected naming name" do
      result = Config.parse_create_params(%{"name" => String.duplicate("a", 61)})

      assert fields(result) == ["name"]
    end

    # One grapheme can carry any number of combining marks, so the character
    # cap alone does not bound the size of a name.
    test "a one-character name of thousands of combining marks is rejected naming name" do
      name = "a" <> String.duplicate("́", 5_000)

      assert String.length(name) == 1
      assert byte_size(name) == 10_001

      assert fields(Config.parse_create_params(%{"name" => name})) == ["name"]
      assert fields(Config.new(name: name)) == ["name"]
      assert fields(Config.new(%{"name" => name})) == ["name"]
    end

    test "an oversized name gets the same message as a name with too many characters" do
      {:error, {:invalid_room_params, [too_many_characters]}} =
        Config.new(name: String.duplicate("a", 61))

      {:error, {:invalid_room_params, [too_many_bytes]}} =
        Config.new(name: "a" <> String.duplicate("́", 5_000))

      assert too_many_bytes == too_many_characters
    end

    test "60 four-byte emoji are accepted" do
      name = String.duplicate("😀", 60)

      assert byte_size(name) == 240
      assert {:ok, %Config{name: ^name}, _} = Config.parse_create_params(%{"name" => name})
      assert {:ok, %Config{name: ^name}} = Config.new(name: name)
    end

    test "60 multi-codepoint emoji sequences are accepted" do
      family = String.duplicate("👨‍👩‍👧‍👦", 60)
      # The longest emoji sequence Unicode recommends: ten codepoints, 35 bytes.
      kiss = String.duplicate("🧑🏻‍❤️‍💋‍🧑🏿", 60)

      assert {String.length(family), byte_size(family)} == {60, 1500}
      assert {String.length(kiss), byte_size(kiss)} == {60, 2100}

      for name <- [family, kiss] do
        assert {:ok, %Config{name: ^name}, _} = Config.parse_create_params(%{"name" => name})
        assert {:ok, %Config{name: ^name}} = Config.new(name: name)
      end
    end

    test "a non-string name is rejected naming name" do
      assert fields(Config.parse_create_params(%{"name" => 42})) == ["name"]
      assert fields(Config.parse_create_params(%{"name" => %{"first" => "x"}})) == ["name"]
      assert fields(Config.parse_create_params(%{"name" => ["x"]})) == ["name"]
    end
  end

  describe "parse_create_params/1 bot difficulty" do
    test "an unknown difficulty returns an error whose field path is bot_difficulty" do
      body = %{"seats" => %{"seat_2" => "ai"}, "bot_difficulty" => "expert"}

      assert {:error, {:invalid_room_params, [%{field: "bot_difficulty", message: message}]}} =
               Config.parse_create_params(body)

      assert message =~ "random"
      assert message =~ "basic"
      assert message =~ "smart"
    end

    test "null, non-string and wrongly-cased difficulties are rejected" do
      assert fields(Config.parse_create_params(%{"bot_difficulty" => nil})) == ["bot_difficulty"]
      assert fields(Config.parse_create_params(%{"bot_difficulty" => 1})) == ["bot_difficulty"]

      assert fields(Config.parse_create_params(%{"bot_difficulty" => "Smart"})) ==
               ["bot_difficulty"]
    end
  end

  describe "parse_create_params/1 unknown fields" do
    test "a body containing settings returns an error whose field path is settings" do
      body = %{
        "name" => "Friday",
        "settings" => %{"min_games" => 1, "time_limit" => 0, "private" => false}
      }

      assert {:error, {:invalid_room_params, [%{field: "settings", message: message}]}} =
               Config.parse_create_params(body)

      assert is_binary(message)
    end

    test "a body containing room returns an error whose field path is room" do
      body = %{"room" => %{"name" => "Friday"}}

      assert fields(Config.parse_create_params(body)) == ["room"]
    end

    test "solo cannot be supplied by the caller" do
      assert fields(Config.parse_create_params(%{"solo" => true})) == ["solo"]
    end

    test "password and is_dev_room are rejected" do
      body = %{"password" => "hunter2", "is_dev_room" => true}

      assert fields(Config.parse_create_params(body)) == ["is_dev_room", "password"]
    end

    test "an unknown key never mints an atom" do
      key = "zz_room_body_never_an_atom_#{System.unique_integer([:positive])}"

      assert fields(Config.parse_create_params(%{key => 1})) == [key]
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "an atom-keyed body is not read as a request body" do
      assert fields(Config.parse_create_params(%{name: "Friday"})) == [":name"]
    end
  end

  describe "parse_create_params/1 seats" do
    test "seat_5 and seat_1 each return an error with that dotted path" do
      assert fields(Config.parse_create_params(%{"seats" => %{"seat_5" => "ai"}})) ==
               ["seats.seat_5"]

      assert fields(Config.parse_create_params(%{"seats" => %{"seat_1" => "ai"}})) ==
               ["seats.seat_1"]

      both = %{"seats" => %{"seat_5" => "ai", "seat_1" => "open"}}

      assert fields(Config.parse_create_params(both)) == ["seats.seat_1", "seats.seat_5"]
    end

    test "a seat value of private returns an error for that seat" do
      body = %{"seats" => %{"seat_2" => "ai", "seat_3" => "private"}}

      assert {:error, {:invalid_room_params, [%{field: "seats.seat_3", message: message}]}} =
               Config.parse_create_params(body)

      assert message =~ "ai"
      assert message =~ "open"
    end

    test "null, human and non-string seat values are rejected for that seat" do
      assert fields(Config.parse_create_params(%{"seats" => %{"seat_2" => nil}})) ==
               ["seats.seat_2"]

      assert fields(Config.parse_create_params(%{"seats" => %{"seat_3" => "human"}})) ==
               ["seats.seat_3"]

      assert fields(Config.parse_create_params(%{"seats" => %{"seat_4" => true}})) ==
               ["seats.seat_4"]
    end

    test "seats given as a string, list or null returns an error for seats" do
      assert fields(Config.parse_create_params(%{"seats" => "ai"})) == ["seats"]
      assert fields(Config.parse_create_params(%{"seats" => ["ai", "ai", "ai"]})) == ["seats"]
      assert fields(Config.parse_create_params(%{"seats" => nil})) == ["seats"]
    end
  end

  describe "parse_create_params/1 error collection" do
    test "a body with three separate problems returns three errors" do
      body = %{
        "settings" => %{"private" => true},
        "bot_difficulty" => "expert",
        "seats" => %{"seat_5" => "ai"}
      }

      assert {:error, {:invalid_room_params, errors}} = Config.parse_create_params(body)
      assert length(errors) == 3

      assert Enum.sort(Enum.map(errors, & &1.field)) ==
               ["bot_difficulty", "seats.seat_5", "settings"]

      assert Enum.all?(errors, &(is_binary(&1.field) and is_binary(&1.message)))
      assert Enum.all?(errors, &(Enum.sort(Map.keys(&1)) == [:field, :message]))
    end

    test "errors come in a stable order: name, seats, bot_difficulty, then unknown keys sorted" do
      body = %{
        "zeta" => 1,
        "alpha" => 1,
        "bot_difficulty" => "expert",
        "seats" => %{"seat_9" => "ai", "seat_2" => "private", "seat_0" => "ai"},
        "name" => 42
      }

      assert fields(Config.parse_create_params(body)) == [
               "name",
               "seats.seat_2",
               "seats.seat_0",
               "seats.seat_9",
               "bot_difficulty",
               "alpha",
               "zeta"
             ]
    end

    test "each field path appears once" do
      body = %{"name" => 42, "bot_difficulty" => "expert"}
      paths = fields(Config.parse_create_params(body))

      assert paths == Enum.uniq(paths)
    end

    test "a body that is not a map returns a single error" do
      for body <- [nil, "name=Friday", ["name"], 42] do
        assert {:error, {:invalid_room_params, [%{field: "body", message: message}]}} =
                 Config.parse_create_params(body)

        assert is_binary(message)
      end
    end

    test "a config struct is not a request body" do
      assert fields(Config.parse_create_params(%Config{})) == ["body"]
    end
  end

  describe "serialization" do
    test "serialize/1 emits difficulty and rule set as strings and the four fields only" do
      {:ok, config} = Config.new(name: "Friday", bot_difficulty: :smart, solo: true)

      assert Config.serialize(config) == %{
               name: "Friday",
               bot_difficulty: "smart",
               rule_set: "finnish",
               solo: true
             }
    end

    test "serialize/1 of the default config" do
      {:ok, config} = Config.new()

      assert Config.serialize(config) == %{
               name: nil,
               bot_difficulty: "basic",
               rule_set: "finnish",
               solo: false
             }
    end

    test "serialize/1 is JSON-encodable" do
      {:ok, config} = Config.new(bot_difficulty: :random)

      assert config |> Config.serialize() |> Jason.encode!() |> Jason.decode!() ==
               %{
                 "name" => nil,
                 "bot_difficulty" => "random",
                 "rule_set" => "finnish",
                 "solo" => false
               }
    end
  end

  describe "accepted_fields/0" do
    test "lists the accepted top-level request fields" do
      assert Config.accepted_fields() == [
               "name",
               "seats",
               "bot_difficulty",
               "rule_set",
               "ads_aware"
             ]
    end

    test "every accepted field is accepted and nothing else is" do
      body = %{
        "name" => "Friday",
        "seats" => %{"seat_2" => "open"},
        "bot_difficulty" => "basic"
      }

      assert Map.keys(body) -- Config.accepted_fields() == []
      assert {:ok, _, _} = Config.parse_create_params(body)
    end
  end

  # The value constraints the OpenAPI spec is checked against. Each is tied to
  # what the parser really does, so an accessor cannot drift from the parser.
  describe "difficulties/0" do
    test "lists the difficulty wire strings in declared order" do
      assert Config.difficulties() == ["random", "basic", "smart"]
    end

    test "every listed difficulty parses to its atom and nothing else parses" do
      for wire <- Config.difficulties() do
        assert {:ok, %Config{bot_difficulty: difficulty}, _} =
                 Config.parse_create_params(%{"bot_difficulty" => wire})

        assert Atom.to_string(difficulty) == wire
      end

      assert fields(Config.parse_create_params(%{"bot_difficulty" => "expert"})) ==
               ["bot_difficulty"]
    end

    test "the rejection message lists them" do
      {:error, {:invalid_room_params, [%{message: message}]}} =
        Config.parse_create_params(%{"bot_difficulty" => "expert"})

      assert message == "must be one of: " <> Enum.join(Config.difficulties(), ", ")
    end
  end

  describe "seat_keys/0 and seat_values/0" do
    test "list the three non-host seats in seat order and the two seat values" do
      assert Config.seat_keys() == ["seat_2", "seat_3", "seat_4"]
      assert Config.seat_values() == ["ai", "open"]
    end

    test "every listed seat takes every listed value and nothing else" do
      for key <- Config.seat_keys(), value <- Config.seat_values() do
        assert {:ok, _, _} = Config.parse_create_params(%{"seats" => %{key => value}})
      end

      for key <- Config.seat_keys() do
        assert fields(Config.parse_create_params(%{"seats" => %{key => "human"}})) ==
                 ["seats." <> key]
      end

      assert fields(Config.parse_create_params(%{"seats" => %{"seat_5" => "ai"}})) ==
               ["seats.seat_5"]
    end

    test "the rejection message lists the seat values" do
      {:error, {:invalid_room_params, [%{message: message}]}} =
        Config.parse_create_params(%{"seats" => %{"seat_2" => "human"}})

      assert message == "must be one of: " <> Enum.join(Config.seat_values(), ", ")
    end
  end

  describe "max_name_length/0" do
    test "is the character cap the parser enforces" do
      cap = Config.max_name_length()

      assert cap == 60
      assert {:ok, _, _} = Config.parse_create_params(%{"name" => String.duplicate("a", cap)})

      assert fields(Config.parse_create_params(%{"name" => String.duplicate("a", cap + 1)})) ==
               ["name"]
    end
  end

  describe "put_seat/3" do
    test "replaces whatever the config said about the seat and nothing else" do
      friend = Ecto.UUID.generate()

      {:ok, config} =
        Config.new(%{
          seat_requirements: %{east: 100, south: 1000},
          seat_holds: %{west: friend},
          password_seats: [:east]
        })

      password = config.seat_password

      assert %{seat_requirements: %{south: 1000}, seat_holds: %{west: ^friend}} =
               bot = Config.put_seat(config, :east, :bot)

      assert bot.password_seats == []
      assert bot.seat_password == password

      held = Config.put_seat(config, :south, {:held, friend})
      assert held.seat_requirements == %{east: 100}
      assert held.seat_holds == %{west: friend, south: friend}

      opened = Config.put_seat(config, :west, {:open, 1000, true})
      assert opened.seat_holds == %{}
      assert opened.seat_requirements == %{east: 100, south: 1000, west: 1000}
      assert opened.password_seats == [:east, :west]
      assert opened.seat_password == password

      assert Config.put_seat(config, :east, {:open, 100, true}) == config
      assert Config.put_seat(%Config{}, :east, {:open, 0, true}).seat_password =~ ~r/\A\d{4}\z/
    end

    test "parse_seat_entry/1 takes a create request's seat values and names the field seat" do
      friend = Ecto.UUID.generate()

      assert Config.parse_seat_entry("ai") == {:ok, :bot}
      assert Config.parse_seat_entry("open") == {:ok, {:open, 0, false}}

      assert Config.parse_seat_entry(%{"type" => "held", "user_id" => friend}) ==
               {:ok, {:held, friend}}

      for bad <- [nil, "closed", %{"type" => "open", "min_games" => 50}] do
        assert {:error, {:invalid_room_params, [%{field: "seat"}]}} = Config.parse_seat_entry(bad)
      end
    end
  end
end
