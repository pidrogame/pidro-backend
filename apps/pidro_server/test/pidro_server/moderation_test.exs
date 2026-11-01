defmodule PidroServer.ModerationTest do
  use ExUnit.Case, async: true

  alias PidroServer.Moderation

  doctest Moderation

  @refused [
    # English
    "fuck",
    "FUCK YOU",
    "you fucking idiot",
    "what a cunt",
    "son of a bitch!",
    "shit hand",
    "go away, retard",
    "nigger",
    # Swedish
    "din fitta",
    "Kuk",
    "jävla hora",
    "knulla dig",
    "bög",
    "rövhål",
    # Finnish
    "vittu",
    "Voi vittu mitä paskaa",
    "kusipää",
    "kyrpä",
    "senkin huora",
    "mulkku",
    # Simple evasions
    "f u c k",
    "f.u.c.k",
    "f-u-c-k you",
    "Ali I.D.I.O.T",
    "ｆｕｃｋ",
    "vitttu",
    "sh1t",
    "$hit",
    "fuuuuck",
    "v1ttu",
    "vittuuuu",
    "k u k",
    "p4sk4",
    "b1tch",
    "@sshole",
    "Fuck_Face",
    "asshole2000"
  ]

  @allowed [
    # Clean Nordic names that contain a listed string
    "Kukkonen",
    "Kukka",
    "Hitchcock",
    "Scunthorpe",
    "Dickson",
    "Sussex",
    "Matti Vitikainen",
    "Pekka Paskanen",
    "Horace",
    "Kristoffer Kuksson",
    "Bögberg",
    "Annika",
    "Åsa Lindström",
    "Jyväskylä",
    "Sjöberg",
    # Clean words and table talk in the three languages
    "Hyvä peli!",
    "Kiitos ja hyvää yötä",
    "Tack för spelet",
    "Bra bud, partner",
    "Nice bid, partner",
    "Good game, well played",
    "Sorry, my mistake",
    "Kuka jakaa?",
    "Pass, pass, pass",
    "Hej hej",
    "Shitake mushrooms",
    "Grape juice",
    "I passed the assessment",
    "Paskahousu is a card game",
    "mikko_83",
    "anna 1 2 3",
    # Words a doubled letter or a split away from a listed one
    "horror",
    "Horror_Fan",
    "God morron",
    "Spelet är slut",
    "Kram och kyss",
    "fagott",
    "Niall Horan",
    "Mo Ron",
    "Prick",
    "Kiki",
    "rysä"
  ]

  test "bad words in English, Swedish and Finnish, and simple evasions, are refused" do
    assert Enum.filter(@refused, &Moderation.allowed?/1) == []
  end

  test "clean Nordic names and words pass" do
    assert Enum.reject(@allowed, &Moderation.allowed?/1) == []
  end

  test "text that is not valid UTF-8 or is very long is not allowed" do
    refute Moderation.allowed?(<<0xFF, "hej">>)
    refute Moderation.allowed?(String.duplicate("hej ", 300))
  end
end
