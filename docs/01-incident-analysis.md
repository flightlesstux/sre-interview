# Task 1: Why Prometheus keeps running out of disk and memory

## Summary

`mock-service` exports `service_request_total` with a `request_id` label that
holds a fresh UUID for every request. Every request therefore creates a new
time series that never goes away. Prometheus memory and disk scale with the
number of active series, so the server grows until it is OOM-killed or fills
its volume. The Grafana dashboard "looked healthy" because `rate()` over
series that only ever hold the value `1` is zero, so the panels quietly
rendered nothing while nobody had configured any alerts that could page.

## Evidence (baseline stack, kind cluster, first four minutes)

Measured against the unmodified repo with `./setup.sh`:

| Time after start | `/metrics` payload | `service_request_total` series | Samples per scrape |
|------------------|--------------------|--------------------------------|--------------------|
| 90 s             | 720 KB             | 3 031                          | 5 426              |
| 210 s            | 900 KB             | 3 691                          | 7 398              |

Prometheus TSDB status at 210 s:

```
headStats: numSeries=7403
labelValueCountByLabelName: request_id=3691, __name__=17, team=5
```

`request_id` is the only label with unbounded values. Series growth is
linear with request volume, roughly 1 000 new series per minute for this
toy app, and it never plateaus because the app keeps every label
combination in memory forever (the `prometheus_client` registry never
expires children). A real service at 1 000 req/s would create 3.6 million
series per hour.

What the dashboard showed:

```
sum(rate(service_request_total[5m]))            => 0
sum(rate(service_request_total[5m])) by (team)  => 0
```

Each series is created with value `1` and never incremented again, so the
per-series rate is `0`, and the sum of zeros is zero. The "Request Rate"
panels were flat lines at zero the whole time, which reads as "healthy" if
you do not know the service is actually serving 30 req/s.

## Root cause chain

1. **Unbounded label cardinality.** `request_id` (a UUID) is used as a metric
   label. Per-request identifiers belong in logs or traces, never in metric
   labels.
2. **No guard rails on the scrape path.** No `sampleLimit`, `labelLimit` or
   scrape timeout on the ServiceMonitor or Prometheus CR, so Prometheus
   accepted an ever-growing scrape until it died.
3. **No self-monitoring.** Prometheus did not scrape itself, so
   `prometheus_tsdb_head_series`, WAL size and RSS were not visible.
4. **No alerting.** `ruleSelector` was set but no `PrometheusRule` existed
   and there was no Alertmanager. "The on-call rotation has been quiet"
   because nothing could ever page.
5. **Ephemeral storage.** The Prometheus CR had no `storage` block, so the
   TSDB lived on an `emptyDir` inside the node's container filesystem. That
   is the "disk" that filled up, and every restart lost all data.
6. **Retention settings that do not protect the disk.** `retention: 2h` and
   `retentionSize: 1GB` sound safe, but `retentionSize` only counts
   persisted blocks. The head block and the WAL (the last 2-3 hours of data)
   are not counted, and with millions of series they alone exceed 1 GB.
7. **Dashboard label mismatch hid the app label.** The panel queried
   `exported_service` because Prometheus renamed the app's `service` label
   on ingest (`honor_labels: false`). That worked by accident and is easy
   to break.

## Fix

### Application (`app/app.py`)

- Removed the `request_id` label. `service_request_total` now has exactly
  `services x teams = 15` series.
- Added `service_request_duration_seconds` histogram with a bounded set of
  buckets so latency is observable too.
- Added optional `TEAM` env var so one instance can be pinned to a tenant
  (used in task 2).

### Prometheus CR (`k8s/prometheus-operator/prometheus.yaml`)

- `enforcedSampleLimit: 5000`, `enforcedLabelLimit: 20`, label name and
  value length limits. A misbehaving exporter now fails its scrape
  (`up == 0`) instead of taking the whole server down.
- Persistent storage: 5Gi PVC. `retentionSize: 3GB` leaves headroom for
  the WAL and the block being compacted. `retention: 24h`.
- Alertmanager wired in via `alerting.alertmanagers`.

### ServiceMonitors (`k8s/prometheus-operator/servicemonitor.yaml`)

- `scrapeTimeout: 10s` and `honorLabels: true` on the app.
- New `prometheus-self` ServiceMonitor so the server observes itself.

### Alerting (`k8s/prometheus-operator/rules.yaml`, `alertmanager.yaml`)

Recording rules that pre-aggregate request rate per team and per
team/service (also the federation surface for task 2), and alerts for:

- `TargetDown`, `ScrapeSampleLimitExceeded`
- `PrometheusHeadSeriesHigh`, `PrometheusSeriesGrowthAbnormal` (the
  fingerprint of this incident)
- `PrometheusStorageNearlyFull`, `PrometheusScrapeTooSlow`,
  `PrometheusRuleEvaluationFailures`
- `ServiceRequestRateZero` (would have fired on day one: the dashboard's
  zero was not "healthy")
- `ServiceMetricCardinalityHigh` (fires when `service_request_total` has
  more than 100 series)

A minimal Alertmanager is deployed with a null receiver; in production the
receiver would be the pager.

### Dashboard (`k8s/base/grafana-dashboard.yaml`)

- Queries use the real `service` label.
- Added latency p95, series count, firing alerts, targets up.
- Added a "Prometheus health" row: head series, series created per second,
  TSDB size (blocks and WAL separately), scrape duration, RSS, samples
  appended. These are the panels that would have shown the problem on the
  first day.

### Housekeeping

- `grafana/` and `prometheus/` directories were docker-compose leftovers
  that nothing in `setup.sh` used and that had already diverged from the
  ConfigMaps. Removed to keep one source of truth.
- `kind-config.yaml` now also maps Alertmanager to `localhost:9093`.

## Verification

After `./setup.sh` on the fixed branch:

```bash
# 15 series, not thousands
curl -s 'localhost:9090/api/v1/query?query=count(service_request_total)'

# real request rate, not zero
curl -s 'localhost:9090/api/v1/query?query=sum(rate(service_request_total[5m]))'

# no label with unbounded values
curl -s localhost:9090/api/v1/status/tsdb | jq '.data.labelValueCountByLabelName'

# storage is a PVC now
kubectl get pvc -n sre-challenge

# rules loaded, nothing firing
curl -s localhost:9090/api/v1/rules | jq '.data.groups[].name'
curl -s localhost:9093/api/v2/alerts
```

Measured on the same kind cluster after applying the fix (mock-service
restarted, Prometheus recreated on a PVC):

| Metric                                   | Before (210 s) | After   |
|------------------------------------------|----------------|---------|
| `/metrics` payload                       | 900 KB         | 16 KB   |
| `service_request_total` series           | 3 691          | 15      |
| Prometheus head series (total)           | 7 403          | 784     |
| `sum(rate(service_request_total[2m]))`   | 0              | 25 req/s|
| Label with most values                   | `request_id` (3 691) | `__name__` (261) |
| Scrape targets                           | mock-service   | mock-service, prometheus |
| Rule groups loaded                       | 0              | 3 (11 rules) |
| Alertmanager attached                    | none           | 1       |
| Storage                                  | emptyDir       | 5Gi PVC |

Note on the missing CRDs: the operator's Alertmanager controller refused to
reconcile until the `AlertmanagerConfig` CRD existed (it was not in
`k8s/infra/crds/`). `ThanosRuler` was missing as well and produced a
constant error loop in the operator log. Both CRDs are now shipped and
applied by `setup.sh`.

## What I would do differently in production

- Put the cardinality guard rails in the platform defaults (Helm values or
  a Kyverno policy that rejects ServiceMonitors without `sampleLimit`).
- Add a CI check on exporters: scrape `/metrics` in the pipeline and fail
  when a label has more than N distinct values.
- Ship `prometheus_tsdb_head_series` and `process_resident_memory_bytes`
  as SLO-style alerts to the platform team, not the tenants.
- Use a long-term store (Thanos or Mimir) so local retention can be short
  and disk is no longer the failure mode. See task 2.
