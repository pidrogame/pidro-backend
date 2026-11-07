defmodule PidroServer.SettingsTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Settings

  test "get/2 answers the default until a value is stored, then the value" do
    assert Settings.get(:some_flag, :none) == :none

    assert :ok = Settings.put(:some_flag, true)
    assert Settings.get(:some_flag, :none) == true

    assert :ok = Settings.put("some_flag", %{"nested" => [1, 2]})
    assert Settings.get("some_flag", :none) == %{"nested" => [1, 2]}
  end

  test "the ad values default to the brief's starting values with the kill switch off" do
    assert Settings.ads() == %{
             ads_enabled: false,
             ads_free_games: 10,
             ads_early_every_n: 3,
             ads_games_until_steady: 40,
             ads_steady_every_n: 2
           }
  end

  test "put_ads/1 saves every value and ads/0 reads them back" do
    assert {:ok, _} =
             Settings.put_ads(%{
               "ads_enabled" => "true",
               "ads_free_games" => "5",
               "ads_early_every_n" => "4",
               "ads_games_until_steady" => "30",
               "ads_steady_every_n" => "1"
             })

    assert Settings.ads() == %{
             ads_enabled: true,
             ads_free_games: 5,
             ads_early_every_n: 4,
             ads_games_until_steady: 30,
             ads_steady_every_n: 1
           }
  end

  test "an ad value stored by hand reads as its type, or as its default when it has none" do
    Settings.put(:ads_enabled, "true")
    Settings.put(:ads_free_games, "lots")
    Settings.put(:ads_early_every_n, "4")

    assert %{ads_enabled: true, ads_free_games: 10, ads_early_every_n: 4} = Settings.ads()
  end

  test "put_ads/1 saves nothing when one value is invalid" do
    assert {:error, changeset} =
             Settings.put_ads(%{"ads_enabled" => "true", "ads_steady_every_n" => "0"})

    assert "must be greater than or equal to 1" in errors_on(changeset).ads_steady_every_n
    assert Settings.ads().ads_enabled == false
  end
end
