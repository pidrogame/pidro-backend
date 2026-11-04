defmodule PidroServer.Leagues.Player do
  @moduledoc "A player's lasting league and preferences; absence means Deuce."
  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "league_players" do
    field :league, :string, default: "deuce"
    field :hidden, :boolean, default: false
    field :intro_seen, :boolean, default: false
  end
end
