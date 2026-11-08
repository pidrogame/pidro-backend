defmodule PidroServer.Repo.Migrations.GiveBotCharactersTheirVoices do
  use Ecto.Migration

  # How each character talks at the table (PID-408), unless the admin already
  # chose otherwise. A character not in the catalogue yet is left to the admin.
  @voices [
    {"marcel", "cheerful", "normal"},
    {"antti", "teasing", "chatty"},
    {"jocke", "dry", "normal"},
    {"bengt", "dry", "sparse"},
    {"stig", "cheerful", "chatty"},
    {"gosta", "warm", "sparse"},
    {"gun", "warm", "chatty"},
    {"siv", "dry", "normal"},
    {"majlis", "warm", "normal"},
    {"beau", "cheerful", "chatty"},
    {"remy", "warm", "normal"},
    {"alcide", "dry", "sparse"},
    {"celeste", "teasing", "normal"},
    {"delphine", "cheerful", "normal"},
    {"odile", "dry", "normal"}
  ]

  def up do
    for {id, voice, appetite} <- @voices do
      execute """
      UPDATE bot_profiles SET voice = '#{voice}', appetite = '#{appetite}'
      WHERE id = '#{id}' AND voice = 'dry' AND appetite = 'normal'
      """
    end
  end

  def down do
    for {id, voice, appetite} <- @voices do
      execute """
      UPDATE bot_profiles SET voice = 'dry', appetite = 'normal'
      WHERE id = '#{id}' AND voice = '#{voice}' AND appetite = '#{appetite}'
      """
    end
  end
end
