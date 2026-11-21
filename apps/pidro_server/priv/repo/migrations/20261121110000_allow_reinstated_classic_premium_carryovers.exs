defmodule PidroServer.Repo.Migrations.AllowReinstatedClassicPremiumCarryovers do
  use Ecto.Migration

  # An imported player granted after their store Premium lapsed (PID-496).
  def up do
    drop constraint(:classic_premium_carryovers, :classic_premium_state_is_valid)

    create constraint(:classic_premium_carryovers, :classic_premium_state_is_valid,
             check: "state IN ('pending', 'granted', 'imported', 'reinstated', 'ended', 'none')"
           )
  end

  # A reinstated player holds a grant like any granted one.
  def down do
    execute "UPDATE classic_premium_carryovers SET state = 'granted' WHERE state = 'reinstated'"
    drop constraint(:classic_premium_carryovers, :classic_premium_state_is_valid)

    create constraint(:classic_premium_carryovers, :classic_premium_state_is_valid,
             check: "state IN ('pending', 'granted', 'imported', 'ended', 'none')"
           )
  end
end
