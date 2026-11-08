defmodule PidroServer.BotCatalogue.VoiceMigrationTest do
  # A disposable database where every migration ran for real.
  use PidroServer.ArchiveCase, async: false

  alias PidroServer.BotCatalogue.Profile

  @columns {20_261_108_160_000, PidroServer.Repo.Migrations.AddVoiceAndAppetiteToBotProfiles}
  @voices {20_261_108_160_100, PidroServer.Repo.Migrations.GiveBotCharactersTheirVoices}

  defp crew,
    do: Repo.all(from p in Profile, select: {p.id, p.voice, p.appetite}, order_by: p.id)

  defp set(id, changes), do: Repo.update_all(from(p in Profile, where: p.id == ^id), set: changes)

  defp down({version, migration}), do: Ecto.Migrator.down(Repo, version, migration, log: false)
  defp up({version, migration}), do: Ecto.Migrator.up(Repo, version, migration, log: false)

  defp add(id),
    do:
      Repo.query!(
        "INSERT INTO bot_profiles (id, name, inserted_at, updated_at) VALUES ($1, $1, now(), now())",
        [id]
      )

  test "gives the crew their voices, leaves an edited character alone, and runs back down" do
    assert crew() == [
             {"antti", "teasing", "chatty"},
             {"jocke", "dry", "normal"},
             {"marcel", "cheerful", "normal"}
           ]

    :ok = down(@voices)

    assert crew() == [
             {"antti", "dry", "normal"},
             {"jocke", "dry", "normal"},
             {"marcel", "dry", "normal"}
           ]

    :ok = down(@columns)

    columns =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'bot_profiles'"
      )

    refute Enum.any?(columns.rows, &(&1 in [["voice"], ["appetite"]]))

    :ok = up(@columns)

    assert_raise Postgrex.Error, ~r/supported_voice/, fn -> set("antti", voice: "shouty") end
    assert_raise Postgrex.Error, ~r/supported_appetite/, fn -> set("antti", appetite: "never") end

    # Characters the admin made meanwhile: Bengt untouched, Gun already
    # edited to teasing, Majlis already chatty, and one not in the table.
    for id <- ~w(bengt gun majlis zelda), do: add(id)
    set("gun", voice: "teasing")
    set("majlis", appetite: "chatty")
    :ok = up(@voices)

    assert crew() == [
             {"antti", "teasing", "chatty"},
             {"bengt", "dry", "sparse"},
             {"gun", "teasing", "normal"},
             {"jocke", "dry", "normal"},
             {"majlis", "dry", "chatty"},
             {"marcel", "cheerful", "normal"},
             {"zelda", "dry", "normal"}
           ]

    # Down undoes only what it set.
    :ok = down(@voices)

    assert crew() == [
             {"antti", "dry", "normal"},
             {"bengt", "dry", "normal"},
             {"gun", "teasing", "normal"},
             {"jocke", "dry", "normal"},
             {"majlis", "dry", "chatty"},
             {"marcel", "dry", "normal"},
             {"zelda", "dry", "normal"}
           ]
  end
end
