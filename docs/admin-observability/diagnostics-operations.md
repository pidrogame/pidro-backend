# Diagnostics operations

The branch writes JSON to stdout locally and in releases. **No hosted ingestion
has been provisioned or activated.** The route below is an operator recipe,
not a deployed service. Keep access limited to operators: identifiers are private
operational data even without hands, email or credentials.

## Local checks and incident lookup

```sh
mise exec -- mix test apps/pidro_server/test/pidro_server/diagnostics_test.exs \
  apps/pidro_server/test/pidro_server_web/channels/game_channel_test.exs \
  apps/pidro_server/test/pidro_server_web/controllers/api/game_report_controller_test.exs
mise exec -- mix precommit
```

At production's unchanged `info` level, each applied move is one
`action_applied` line (with `action_id` when a player sent it); a refused or
timed-out action is its `action_outcome`, then optional `state_received`.
Filter by instance **and** action ID. Room codes alone are reusable.
`action_received`, `state_broadcast` and `state_pushed` are `debug`: lower the
level locally to follow a revision to each recipient.
For a report, search `report_created.report_id`, then use the authenticated
admin inspector/internal context (`GameReports.admin_get/1` or `admin_search/1`).
Never put the report's event buffer into a log message or public JSON endpoint.

Timeout outcomes are `unknown`: the engine might apply the queued call later.
Do not replay an action based on a missing log, client timeout, or missing ack.
Client labels/times/acks are untrusted and sampling may discard them.

## Build identity and rollback

`config/runtime.exs` selects `KAMAL_VERSION`, falling back to `SERVER_BUILD`, then
`unknown` for local development. Kamal 2.12 injects `KAMAL_VERSION` into each app
container from the same `config.version` used for its image tag. Rollback sets
that version to the rollback target before boot. Our Deploy workflow checks out
the green commit and verifies the running version equals its exact Git SHA.
Do not set a static `SERVER_BUILD` in deploy YAML or derive it from the operator's
checkout: those values would mislabel rollbacks.

After authorized deployment, the operator should compare these read-only checks:

```sh
bundle exec kamal app version --quiet
bundle exec kamal app exec --primary --reuse \
  'bin/pidro_server rpc "IO.puts(Application.fetch_env!(:pidro_server, :server_build))"'
```

Both must equal the expected 40-character deployment SHA. Then verify one
`channel_joined`/`action_applied` record carries that SHA. This branch has tested
runtime configuration precedence and local emission, **not a production deploy**.

Source: [Kamal 2.12 app container command](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/commands/app.rb),
[rollback implementation](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/cli/main.rb).

## One managed delivery route: Docker logs → Vector → Better Stack

Use an existing approved Better Stack source. Supply its documented ingest URL
and source token through the collector's secret manager, never this repository
or an Elixir environment variable. Do not enable a new paid source without
approval. There are no provider HTTP calls on game-action or report paths.

Run a pinned Vector collector separately from the app, with a memory/CPU limit
(for example 128 MiB/0.25 CPU) and restart policy. Reading the Docker socket
grants powerful host access even with a read-only mount: use an approved
restricted Docker API proxy or a tightly controlled host service. Restrict
collection to `pidro-backend-web-` containers; exclude Postgres and other apps.

Example Vector YAML (substitute environment variables in the collector only):

```yaml
sources:
  backend:
    type: docker_logs
    include_containers: ["pidro-backend-web-"]
    auto_partial_merge: false

transforms:
  diagnostics:
    type: remap
    inputs: [backend]
    drop_on_error: true
    drop_on_abort: true
    source: |
      . = object!(parse_json!(string!(.message)))
      if !exists(.event) { abort }
      .dt = format_timestamp!(from_unix_timestamp!(int!(.timestamp), unit: "microseconds"), format: "%+")

sinks:
  better_stack:
    type: http
    inputs: [diagnostics]
    method: post
    uri: "${BETTER_STACK_INGEST_URL}"
    auth:
      strategy: bearer
      token: "${BETTER_STACK_SOURCE_TOKEN}"
    encoding:
      codec: json
    compression: gzip
    batch:
      max_events: 100
      max_bytes: 262144
      timeout_secs: 1
    buffer:
      type: memory
      max_events: 1000
      when_full: drop_newest
    request:
      concurrency: 1
      timeout_secs: 5
      retry_attempts: 2
```

This intentionally ships only allowlisted diagnostic records, not ordinary
application messages or raw reports. Run `vector validate` with the selected
pinned collector and an approved test source before activation; this example
has not been exercised against a hosted provider. Confirm source timestamp
parsing and search fields with a harmless synthetic event. Do not print the
collector environment or token during troubleshooting.

References: [Better Stack's Vector recipe](https://betterstack.com/docs/logs/vector/),
[Vector HTTP buffering/retries](https://vector.dev/docs/reference/configuration/sinks/http/),
[Docker source prefix selection](https://vector.dev/docs/reference/configuration/sources/docker_logs/).

## Failure limits, retention and recovery

* The OTP stdout handler has equal sync/drop thresholds (200) and flush threshold
  1000: overload drops rather than switching game callers to synchronous logging.
  The diagnostic helper catches formatter/logger failures; no tasks or custom
  queues are created. Stdout records are best-effort, not a durable audit ledger.
* Provider failure consumes bounded collector memory, two retries with five-second
  request timeouts, then loses that batch. A full buffer drops newest events;
  restarting the collector loses its memory buffer. Backoff can add time beyond
  request timeouts. Do not turn on unbounded retries or a blocking log driver.
* Kamal Docker `local` rotation keeps 100 MiB × 10 files per container.
  Collection never reads from an application mailbox or synchronously gates a move.
  During provider loss, inspect retained local logs; alert on collector drop/error
  metrics through the existing ops system, not by sending more game reports.
* Reports use Postgres, independently of logs. Unavailable quota/storage returns
  503 and does not insert or change game outcomes. Retries are user initiated.
  Five stored reports/hour/user is durable; ten attempts/minute is node-local.
* `GameReports.Cleanup` is supervised and enabled by default, one batch of at most
  1000 rows older than 30 days every 60 seconds. A failure logs
  `report_cleanup_failed` and schedules the next batch; it does not spin or spawn.
  SQL sandbox tests disable the global timer and exercise a separate scheduled
  instance. Check this process and expired-row backlog after deploying migration
  **20261022120200**. A large backlog takes multiple minutes to drain.
* Archive participation wiring is a separate integration prerequisite for games
  without completed stats. Never relax ownership checks to make ingestion green.
  The [contract](diagnostics-contract.md) specifies the exact callback and gaps.
