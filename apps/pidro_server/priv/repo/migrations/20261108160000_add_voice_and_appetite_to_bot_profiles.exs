defmodule PidroServer.Repo.Migrations.AddVoiceAndAppetiteToBotProfiles do
  use Ecto.Migration

  def change do
    alter table(:bot_profiles) do
      add :voice, :string, null: false, default: "dry"
      add :appetite, :string, null: false, default: "normal"
    end

    create constraint(:bot_profiles, :supported_voice,
             check: "voice IN ('cheerful', 'warm', 'dry', 'teasing')"
           )

    create constraint(:bot_profiles, :supported_appetite,
             check: "appetite IN ('sparse', 'normal', 'chatty')"
           )
  end
end
