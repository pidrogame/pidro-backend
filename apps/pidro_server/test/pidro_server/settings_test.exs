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

  test "no version is required until one is saved" do
    assert Settings.update_required() == %{"ios" => nil, "android" => nil}
  end

  test "put_update_required/1 saves a version per platform, with or without a build, and a blank turns it off" do
    assert {:ok, required} =
             Settings.put_update_required(%{
               "ios_version" => "3.4.0",
               "ios_build" => "57",
               "android_version" => "3.3.1",
               "android_build" => ""
             })

    assert required == %{
             "ios" => %{"version" => "3.4.0", "build" => "57"},
             "android" => %{"version" => "3.3.1", "build" => nil}
           }

    assert Settings.update_required() == required

    assert {:ok, %{"ios" => %{"version" => "3.4.0"}, "android" => nil}} =
             Settings.put_update_required(%{"android_version" => ""})

    assert Settings.update_required()["android"] == nil

    # Blanking the version is enough to turn it off, even with a build saved.
    assert {:ok, %{"ios" => nil, "android" => nil}} =
             Settings.put_update_required(%{"ios_version" => ""})
  end

  test "put_update_required/1 saves nothing when a version or build is invalid" do
    for {attrs, field, message} <- [
          {%{"ios_version" => "3.4"}, :ios_version, "must be a version like 3.4.0"},
          {%{"ios_version" => "latest"}, :ios_version, "must be a version like 3.4.0"},
          {%{"android_version" => "3.4.0-beta"}, :android_version,
           "must be a version like 3.4.0"},
          {%{"ios_version" => "3.4.0", "ios_build" => "57a"}, :ios_build,
           "must be a build number like 57"}
        ] do
      assert {:error, changeset} = Settings.put_update_required(attrs)
      assert message in errors_on(changeset)[field], inspect(attrs)
    end

    assert Settings.update_required() == %{"ios" => nil, "android" => nil}
  end

  test "a required version stored by hand that is not a version reads as off" do
    Settings.put(:update_required, %{
      "ios" => %{"version" => "soon", "build" => "1"},
      "android" => %{"version" => "3.4.0", "build" => 57}
    })

    assert Settings.update_required() == %{
             "ios" => nil,
             "android" => %{"version" => "3.4.0", "build" => nil}
           }

    Settings.put(:update_required, "3.4.0")
    assert Settings.update_required() == %{"ios" => nil, "android" => nil}
  end
end
