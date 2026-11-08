defmodule PidroServer.BotCatalogue.SearchStrategyMigrationTest do
  # A disposable database where every migration ran for real.
  use PidroServer.ArchiveCase, async: false

  alias PidroServer.BotCatalogue.Profile

  @migration PidroServer.Repo.Migrations.AddSearchStrategyToBotProfiles
  @version 20_261_108_140_000

  defp crew, do: Repo.all(from p in Profile, select: {p.id, p.strategy, p.tempo}, order_by: p.id)

  defp set(id, changes), do: Repo.update_all(from(p in Profile, where: p.id == ^id), set: changes)

  test "runs down to rulebook and back up, keeping what the admin already changed" do
    assert crew() == [
             {"antti", "search", "slow"},
             {"jocke", "search", "steady"},
             {"marcel", "search", "quick"}
           ]

    :ok = Ecto.Migrator.down(Repo, @version, @migration, log: false)

    assert crew() == [
             {"antti", "rulebook", "slow"},
             {"jocke", "rulebook", "steady"},
             {"marcel", "rulebook", "quick"}
           ]

    assert_raise Postgrex.Error, ~r/supported_strategy/, fn ->
      set("antti", strategy: "search")
    end

    # Before the migration, the admin made Marcel slow and Jocke random.
    set("marcel", tempo: "slow")
    set("antti", tempo: "steady")
    set("jocke", strategy: "random")
    :ok = Ecto.Migrator.up(Repo, @version, @migration, log: false)

    assert crew() == [
             {"antti", "search", "slow"},
             {"jocke", "random", "steady"},
             {"marcel", "search", "slow"}
           ]

    assert {1, _} = set("jocke", strategy: "search")
  end
end
