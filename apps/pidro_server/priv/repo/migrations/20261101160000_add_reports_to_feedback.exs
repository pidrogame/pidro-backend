defmodule PidroServer.Repo.Migrations.AddReportsToFeedback do
  use Ecto.Migration

  # A report is a note about a player (PID-329): one per reporter, reported
  # player and game, the game named in details.
  def change do
    alter table(:feedback) do
      add :reported_user_id, references(:users, type: :uuid, on_delete: :nilify_all)
    end

    create unique_index(:feedback, [:user_id, :reported_user_id, "(details->>'game')"],
             where: "kind = 'report'",
             name: :feedback_one_report_per_game
           )
  end
end
