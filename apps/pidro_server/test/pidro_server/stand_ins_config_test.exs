defmodule PidroServer.StandInsConfigTest do
  # Reads config/runtime.exs with the process environment, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_config Path.expand("../../../../config/runtime.exs", __DIR__)
  @compile_config Path.expand("../../../../config/config.exs", __DIR__)

  # The variables the production block of config/runtime.exs requires.
  @prod_env %{
    "DATABASE_URL" => "ecto://user:pass@localhost/pidro",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "CORS_ORIGINS" => "*",
    "CLASSIC_API_URL" => "https://classic.example.com",
    "CLASSIC_CLAIM_SECRET" => "secret",
    "FB_APP_SECRET" => "secret"
  }

  # What an end-to-end suite sets to point a server at its stand-ins and
  # shorten lifetimes. Production must read none of them (PID-183).
  @stand_in_env %{
    "CI" => "true",
    "PIDRO_E2E" => "1",
    "APPLE_JWKS_URL" => "http://127.0.0.1:4555/auth/keys",
    "CLASSIC_CLAIM_TICKET_TTL_SECONDS" => "1",
    "PASSWORD_RESET_TTL_SECONDS" => "1",
    "PASSWORD_RESET_DEBUG_TOKENS" => "false",
    "PASSWORD_RESET_URL_BASE" => "http://127.0.0.1:5173"
  }

  setup do
    names = Map.keys(@prod_env) ++ Map.keys(@stand_in_env)
    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(@prod_env)
    System.put_env(@stand_in_env)
    :ok
  end

  test "production ignores the stand-in key server, lifetimes and reset overrides" do
    config = runtime_config(:prod)

    assert config[PidroServer.Accounts.ProviderIdentity][:apple_jwks_url] ==
             "https://appleid.apple.com/auth/keys"

    refute Keyword.has_key?(config, PidroServer.Accounts.ClassicClaims)
    refute Keyword.has_key?(config, :password_reset_ttl_seconds)
    refute Keyword.has_key?(config, :password_reset)
  end

  test "outside production the same variables take effect" do
    config = runtime_config(:dev)

    assert config[PidroServer.Accounts.ProviderIdentity][:apple_jwks_url] ==
             "http://127.0.0.1:4555/auth/keys"

    assert config[PidroServer.Accounts.ClassicClaims][:ticket_ttl_seconds] == 1
    assert config[:password_reset_ttl_seconds] == 1
    assert config[:password_reset][:reset_url_base] == "http://127.0.0.1:5173"
    assert config[:password_reset][:debug_tokens] == false
  end

  test "unit tests use cheap real password hashes" do
    assert Application.fetch_env!(:bcrypt_elixir, :log_rounds) == 4
  end

  test "development uses cheap hashes only for explicitly opted-in CI journeys" do
    assert bcrypt_config(:dev)[:log_rounds] == 4

    System.delete_env("CI")
    refute Keyword.has_key?(bcrypt_config(:dev), :log_rounds)

    System.put_env("CI", "true")
    System.delete_env("PIDRO_E2E")
    refute Keyword.has_key?(bcrypt_config(:dev), :log_rounds)
  end

  test "production keeps its hashing cost even with all E2E flags set" do
    refute Keyword.has_key?(bcrypt_config(:prod), :log_rounds)
  end

  test "watching tables boots off in production until deploy config turns it on" do
    saved = System.get_env("WATCHING_TABLES")

    on_exit(fn ->
      if saved,
        do: System.put_env("WATCHING_TABLES", saved),
        else: System.delete_env("WATCHING_TABLES")
    end)

    System.delete_env("WATCHING_TABLES")
    assert compile_config(:prod)[:watching_tables] == false
    refute Keyword.has_key?(runtime_config(:prod), :watching_tables)

    System.put_env("WATCHING_TABLES", "true")
    assert runtime_config(:prod)[:watching_tables] == true
    System.put_env("WATCHING_TABLES", "false")
    assert runtime_config(:prod)[:watching_tables] == false

    # The app's journeys watch a table on the development server they boot.
    assert compile_config(:dev)[:watching_tables] == true
    System.delete_env("PIDRO_E2E")
    assert compile_config(:dev)[:watching_tables] == false
  end

  defp compile_config(env) do
    @compile_config
    |> Config.Reader.read!(env: env, target: :host)
    |> Keyword.fetch!(:pidro_server)
  end

  defp bcrypt_config(env) do
    @compile_config
    |> Config.Reader.read!(env: env, target: :host)
    |> Keyword.get(:bcrypt_elixir, [])
  end

  defp runtime_config(env) do
    # Production without SMTP settings warns on stderr; that is not under test.
    {config, _warning} =
      with_io(:stderr, fn -> Config.Reader.read!(@runtime_config, env: env, target: :host) end)

    Keyword.fetch!(config, :pidro_server)
  end
end
