defmodule PidroServer.Repo.Migrations.SeedNewsPosts do
  use Ecto.Migration

  # The welcome note the app showed as a one-time sheet, published, and two
  # drafts for 3.2.3 that Marcel publishes himself.
  def up do
    now = DateTime.utc_now()

    repo().insert_all("news_posts", [
      %{
        title_en: "Welcome to the new Pidro",
        body_en:
          "This is a test version. You're one of the first to play it, and it's still being built.\nHere today: Finnish and Louisiana rules, tables with friends, bots that fill an empty chair.\nYour old Pidro app keeps working. Nothing there changes.",
        title_sv: "Välkommen till nya Pidro",
        body_sv:
          "Det här är en testversion. Du är en av de första som spelar den, och den är inte färdig än.\nRedan nu: finska regler och Louisiana-regler, bord med vänner, bottar som fyller en tom plats.\nDin gamla Pidro-app fungerar som vanligt. Där ändras ingenting.",
        published_at: ~U[2026-10-26 08:00:00Z],
        inserted_at: now,
        updated_at: now
      },
      %{
        title_en: "The table sounds like Pidro again",
        body_en:
          "The card, the shuffle, the deal, your turn: the sounds you know from the old game. Rather play quietly? Settings → Sound.",
        title_sv: "Bordet låter som Pidro igen",
        body_sv:
          "Kortet, blandningen, given, din tur: ljuden du känner igen från det gamla spelet. Vill du spela tyst? Inställningar → Ljud.",
        published_at: nil,
        inserted_at: now,
        updated_at: now
      },
      %{
        title_en: "Bigger cards, a calmer table",
        body_en:
          "Your cards are bigger and stand upright. Bots play at the old pace, and the seats stay quiet while a hand is on.",
        title_sv: "Större kort, ett lugnare bord",
        body_sv:
          "Dina kort är större och står upprätt. Bottarna spelar i det gamla tempot, och platserna är lugna medan en giv pågår.",
        published_at: nil,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  # A seeded post belongs to the admin once it exists, including on rollback.
  def down, do: :ok
end
