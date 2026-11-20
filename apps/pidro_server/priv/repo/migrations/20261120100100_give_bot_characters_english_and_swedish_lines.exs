defmodule PidroServer.Repo.Migrations.GiveBotCharactersEnglishAndSwedishLines do
  use Ecto.Migration

  # What each character says while thinking (PID-488): `lines` in English,
  # `lines_sv` in Swedish. Characters not listed keep their lines.
  @lines [
    {"bengt", ["Well…", "Hmm, right…", "Hold on…", "Let's see…"],
     ["Nå…", "Jaha, jaha…", "Vänta lite…", "Ska vi se…"]},
    {"gosta", ["Is that so…", "Hm, maybe…", "Let me see…", "Well, there…"],
     ["Jaså…", "Hm, kanske…", "Låt se nu…", "Nå, så där…"]},
    {"gun", ["Well now…", "Hmm, right…", "Wait now…", "Yes, yes…"],
     ["Nå men…", "Hmm, jaha…", "Vänta nu…", "Jo jo…"]},
    {"majlis", ["Oh well…", "Hmm…", "Wait, wait…", "Right, well…"],
     ["Nå ja…", "Hmm…", "Vänta, vänta…", "Jaha, nå…"]},
    {"siv", ["Right…", "There we go…", "Hm, well…", "Well, right…"],
     ["Jaha…", "Så ja…", "Hm, nå…", "Nå, jaha…"]},
    {"stig", ["Well, well…", "Go!", "Hmm, yes…", "That's it…"],
     ["Nå nå…", "Kör!", "Hmm, jo…", "Så där ja…"]},
    {"alcide", ["Oh no…", "Hmm…", "That's good…", "One moment…"],
     ["Nej, nej…", "Hmm…", "Det är bra…", "Ett ögonblick…"]},
    {"beau", ["Well…", "Let's go…", "Hmm, let's see…", "Well now…"],
     ["Nå…", "Kom igen…", "Hmm, få se…", "Ja ja…"]},
    {"celeste", ["Well, cher…", "Let's see…", "Hmm, yeah…", "Well…"],
     ["Nå, kära du…", "Få se…", "Hmm, jo…", "Tja…"]},
    {"delphine", ["Come on now…", "Oh yes!", "Hmm, no…", "Let me think…"],
     ["Kom igen nu…", "Ja visst!", "Hmm, nej…", "Låt mig tänka…"]},
    {"odile", ["Hmm, my dear…", "Wait…", "Well…", "Easy now…"],
     ["Hmm, kära du…", "Vänta…", "Tja…", "Sakta nu…"]},
    {"remy", ["Hmm, cher…", "Oh yes…", "Hold on, cher…", "Let me see…"],
     ["Hmm, du…", "Ja visst…", "Vänta lite…", "Få se nu…"]}
  ]

  def up do
    for {id, english, swedish} <- @lines do
      execute(fn ->
        repo().query!("UPDATE bot_profiles SET lines = $2, lines_sv = $3 WHERE id = $1", [
          id,
          english,
          swedish
        ])
      end)
    end
  end

  # The mixed lists from before are not recorded, so down only takes the
  # Swedish back out; the English stays.
  def down do
    ids = Enum.map(@lines, &elem(&1, 0))

    execute(fn ->
      repo().query!("UPDATE bot_profiles SET lines_sv = '{}' WHERE id = ANY($1)", [ids])
    end)
  end
end
