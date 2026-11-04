defmodule PidroServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PidroServerWeb.Telemetry,
      PidroServer.Repo,
      PidroServer.GameReports.Cleanup,
      # Idle-guest sweep; needs the Repo and the RoomManager (started below by
      # Games.Supervisor) only when a run fires, never at start
      PidroServer.Accounts.GuestReaper,
      PidroServer.Leagues.Closer,
      {DNSCluster, query: Application.get_env(:pidro_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PidroServer.PubSub},
      PidroServer.BotCatalogue,
      # Presence tracking for connected users
      PidroServerWeb.Presence,
      # Aggregate online user count across all channels
      PidroServer.Games.PresenceAggregator,
      # Games domain supervisor - manages rooms and game processes
      PidroServer.Games.Supervisor,
      # Bot infrastructure - available in all environments
      PidroServer.Games.Bots.BotSupervisor,
      PidroServer.Games.Bots.BotManager,
      PidroServer.GameArchive.Maintenance,
      # Provider signing keys are public and safe to cache independently per node.
      PidroServer.Accounts.JwksCache,
      # Node-local rate-limit counters; must be up before the endpoint serves
      {PidroServer.RateLimit, clean_period: :timer.minutes(1)},
      # Privacy-bounded, node-local deferred invite hints. This must remain a
      # single owner unless the deployment adopts a first-party shared store.
      PidroServer.Invites.DeferredMatcher,
      # Work that outlives the request, such as the password reset mail
      {Task.Supervisor, name: PidroServer.TaskSupervisor},
      # Start to serve requests, typically the last entry
      PidroServerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PidroServer.Supervisor]

    with {:ok, _pid} = started <- Supervisor.start_link(children, opts) do
      # Everything rooms need is up now: take over rooms a previous node left.
      send(PidroServer.Games.RoomManager, :restore_rooms)
      started
    end
  end

  # Before anything stops, hand the rooms over to the node that replaces this one.
  @impl true
  def prep_stop(state) do
    PidroServer.Games.RoomManager.release_rooms()
    state
  catch
    :exit, _ -> state
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PidroServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
