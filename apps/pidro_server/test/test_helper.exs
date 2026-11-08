ExUnit.start()
# The server can start before its migrations ran (the umbrella starts it during
# the engine's tests), leaving the bot catalogue on its fallback crew. Tests
# seat characters from the migrated catalogue, as production does.
PidroServer.BotCatalogue.refresh()
Ecto.Adapters.SQL.Sandbox.mode(PidroServer.Repo, :manual)
Code.require_file("support/archive_case.exs", __DIR__)
