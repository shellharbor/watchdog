# Watchdog observability assets

These assets complement the opt-in Prometheus textfile collector integration.
They do not add a Watchdog daemon, network listener, credentials, or new runtime
dependency.

The bundled queries use the default metric `prefix: watchdog`. Keep that prefix
or replace `watchdog_` in the dashboard and rules if your configuration uses a
different prefix. The dashboard's `instance` selector normally comes from the
Prometheus scrape target; a static `instance` label is also supported.

1. Enable `metrics` and `metrics.heartbeat.enabled` in the Watchdog
   configuration. The [`examples/prometheus-heartbeat.yaml`](../examples/prometheus-heartbeat.yaml)
   file is a complete starting point.
2. Configure node_exporter with its textfile collector and let Prometheus scrape
   that node_exporter target.
3. Load [`prometheus/watchdog-alerts.yml`](prometheus/watchdog-alerts.yml) with
   Prometheus. Change the `900`-second stale-heartbeat threshold and `for`
   duration to suit the scheduler; use at least twice the timer/cron interval.
4. Merge [`alertmanager/watchdog-route.example.yml`](alertmanager/watchdog-route.example.yml)
   into the existing Alertmanager configuration and select a real receiver.
5. Import [`grafana/watchdog-overview.json`](grafana/watchdog-overview.json),
   select the Prometheus datasource, and choose an instance.

`watchdog_heartbeat_timestamp_seconds` is only a scheduler-liveness signal. It
updates after a completed full monitor run even when a service is unavailable;
the service-state alerts remain responsible for service health. The metric has
only configured static labels, never a service name, incident ID, command
output, response body, or secret.

A targeted `-s SERVICE` run never refreshes the heartbeat. After an ordinary
run has established one, its previous timestamp is retained and re-exported so
a partial metrics rewrite cannot make the series disappear or look fresh.

The heartbeat alert can evaluate only after Prometheus has observed an initial
heartbeat sample. To alert on a target that has never scraped successfully, use
your existing node_exporter/Prometheus `up` alert for that target.
