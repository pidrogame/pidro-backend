defmodule PidroServer.Repo.Migrations.AddSearchStrategyToBotProfiles do
  use Ecto.Migration

  # The three devs play the odds, each at their own tempo, unless the admin
  # already chose otherwise.
  def up do
    drop constraint(:bot_profiles, :supported_strategy)

    create constraint(:bot_profiles, :supported_strategy,
             check: "strategy IN ('rulebook', 'random', 'search')"
           )

    execute """
    UPDATE bot_profiles SET strategy = 'search'
    WHERE id IN ('antti', 'jocke', 'marcel') AND strategy = 'rulebook'
    """

    execute """
    UPDATE bot_profiles
    SET tempo = CASE id WHEN 'marcel' THEN 'quick' ELSE 'slow' END
    WHERE id IN ('marcel', 'antti') AND tempo = 'steady'
    """
  end

  # Tempos stay; every tempo is valid without this migration.
  def down do
    execute "UPDATE bot_profiles SET strategy = 'rulebook' WHERE strategy = 'search'"
    drop constraint(:bot_profiles, :supported_strategy)

    create constraint(:bot_profiles, :supported_strategy,
             check: "strategy IN ('rulebook', 'random')"
           )
  end
end
