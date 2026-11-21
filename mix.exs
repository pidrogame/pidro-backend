defmodule PidroBackend.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [
        ignore_warnings: "dialyzer.ignore-warnings",
        list_unused_filters: true
      ],
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end

  defp aliases do
    [
      precommit: [
        "hex.audit",
        "deps.audit",
        "sobelow --root apps/pidro_server",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --raise",
        &credo_diff/1,
        "dialyzer"
      ]
    ]
  end

  defp credo_diff(_args) do
    if Mix.shell().cmd("ops/credo-diff") != 0 do
      Mix.raise("Credo found new high-priority issues")
    end
  end
end
