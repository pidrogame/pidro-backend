defmodule PidroServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :pidro_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:ex_unit]
      ],
      releases: releases(),
      # Documentation
      name: "Pidro Server",
      source_url: "https://github.com/pidro/pidro_backend",
      docs: [
        main: "readme",
        extras: ["README.md", "DEPLOYMENT.md"],
        groups_for_modules: [
          "Web Controllers": [
            PidroServerWeb.API.AuthController,
            PidroServerWeb.API.RoomController,
            PidroServerWeb.API.UserController,
            PidroServerWeb.API.ProfileController,
            PidroServerWeb.API.FallbackController
          ],
          "WebSocket Channels": [
            PidroServerWeb.UserSocket,
            PidroServerWeb.LobbyChannel,
            PidroServerWeb.GameChannel,
            PidroServerWeb.Presence
          ],
          "Game Management": [
            PidroServer.Games.Supervisor,
            PidroServer.Games.GameSupervisor,
            PidroServer.Games.GameRegistry,
            PidroServer.Games.RoomManager,
            PidroServer.Games.GameAdapter
          ],
          Accounts: [
            PidroServer.Accounts.Auth,
            PidroServer.Accounts.Token,
            PidroServer.Accounts.User
          ],
          Statistics: [
            PidroServer.Stats,
            PidroServer.Stats.GameStats
          ]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {PidroServer.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:pidro_engine, in_umbrella: true},
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.7.0"},
      {:ecto_sql, "~> 3.14.0"},
      {:postgrex, "~> 0.22.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_view, "~> 1.2.6"},
      {:lazy_html, "~> 0.1.11", only: :test},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5.1", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.29"},
      {:gen_smtp, "~> 1.2"},
      {:req, "~> 0.7"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0.2"},
      {:jason, "~> 1.4.5"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.14.0"},
      {:cors_plug, "~> 3.0"},
      {:hammer, "~> 7.4"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:open_api_spex, "~> 3.22.3"},
      {:eqrcode, "~> 0.2.1"},
      {:openskill, "~> 1.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind pidro_server", "esbuild pidro_server"],
      "assets.deploy": [
        "tailwind pidro_server --minify",
        "esbuild pidro_server --minify",
        "phx.digest"
      ]
    ]
  end

  # Release configuration for production deployments
  defp releases do
    [
      pidro_server: [
        include_executables_for: [:unix],
        applications: [
          pidro_engine: :permanent,
          pidro_server: :permanent
        ],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
