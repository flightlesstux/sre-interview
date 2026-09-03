# Interview questions and answers

Questions an interviewer is likely to ask about this repository, with the
answers grounded in what was actually built, measured and decided. Grouped
by topic. Numbers come from the kind cluster runs recorded in
`01-incident-analysis.md` and `02-multi-tenant-design.md`.

## 1. The incident

**Q: What was actually wrong with the monitoring stack?**
A: `service_request_total` had a `request_id` label holding a fresh UUID per
request. Every request created a new time series that never expired. In
Prometheus, memory and disk scale with the number of active series, so the
server grew until the kernel OOM-killed it or the volume filled. Everything
else (no alerts, no self-monitoring, ephemeral storage) turned a bug into an
outage nobody noticed.

**Q: How did you find it?**
A: Measured before touching anything. Ninety seconds after `./setup.sh` the
`/metrics` payload was 720 KB with 3 031 `service_request_total` series;
at 210 s it was 900 KB and 3 691 series. `/api/v1/status/tsdb` listed
`request_id` as the label with 3 691 distinct values and `team` with 5.
That is a linear growth curve with a single unbounded label, which is the
fingerprint of a cardinality bug. Reading `app.py` confirmed it in one line.

**Q: Why did the dashboard look healthy?**
A: `sum(rate(service_request_total[5m]))` returned 0. Each series was created
with value 1 and never incremented again, so the per-series rate is zero and
the sum of zeros is zero. A flat line at zero is not "healthy", it is "no
data", but with no alert defined on it, nobody could tell the difference. The
"quiet on-call" was silence, not health.

**Q: Why did it run out of disk when `retentionSize` was set to 1GB?**
A: `retentionSize` only counts persisted blocks. The head block (last two to
three hours) and the write-ahead log are not counted. With millions of
series, the WAL alone exceeds 1GB. On top of that, the Prometheus CR had no
`storage` block, so the TSDB lived on an `emptyDir` on the node's container
filesystem. That is the disk that filled, and every restart lost everything.

**Q: Why OOM? Where does the memory go?**
A: The head block keeps every active series and its recent chunks in memory,
plus the inverted index. Rule of thumb is a few kilobytes per active series,
so a million series is several gigabytes. The container had a 1Gi limit.
Growth was linear with traffic, so it was only a matter of when.

**Q: What would the same bug do at production scale?**
A: At 1 000 req/s it creates 3.6 million series per hour. No Prometheus
survives that; you would take down remote-write targets and Grafana with it.

**Q: What is the rule for metric labels?**
A: Label values must be bounded and low cardinality: service, team, method,
status class, region. Anything per-request or per-user (request id, user id,
trace id, email, timestamp, full URL) belongs in logs or traces, never in
metric labels. A histogram bucket boundary is bounded; a raw latency value
is not.

## 2. The fix

**Q: What did you change and in what order?**
A: Layers, from the cause outward:
1. App: removed the label, added a latency histogram with fixed buckets.
2. Scrape guard rails: `enforcedSampleLimit`, label count and length limits
   on the Prometheus CR, `scrapeTimeout` on the ServiceMonitor.
3. Storage: 5Gi PVC, `retention: 24h`, `retentionSize: 3GB` to leave WAL
   headroom.
4. Visibility: a self-monitoring ServiceMonitor, a Prometheus health row on
   the dashboard.
5. Alerting: Alertmanager plus rules for the exact failure modes seen.
Result on the same cluster: 15 series, 16 KB payload, 25 req/s visible.

**Q: Why enforce limits on the Prometheus CR instead of the ServiceMonitor?**
A: `enforcedSampleLimit` on the CR applies to every target, including ones
added later by other people. A limit on one ServiceMonitor protects one
target. In a multi-tenant setup the platform owns the ceiling, teams cannot
raise it from their own objects.

**Q: What happens when a target exceeds the sample limit?**
A: The whole scrape is rejected and `up` goes to 0 for that target. You lose
that target's metrics until it is fixed, but the server stays alive and the
`ScrapeSampleLimitExceeded` alert tells you exactly which target. Losing one
exporter loudly is better than losing the server quietly.

**Q: Why not just drop the label with `metricRelabelings`?**
A: `labeldrop` on `request_id` would leave thousands of samples with
identical label sets in one scrape, which Prometheus rejects as duplicates,
so the effect is the same as a sample limit but harder to reason about. The
real fix is in the exporter; the limit is the safety net.

**Q: Why `honorLabels: true`?**
A: The app already emits a `service` label. With the default
`honor_labels: false`, Prometheus renames it to `exported_service` because
the operator adds its own `service` label with the Kubernetes Service name.
The original dashboard queried `exported_service`, which worked by accident.
With `honorLabels: true` the app's label wins and the Kubernetes name is
still available as `job`.

**Q: Which alerts did you add and why those?**
A: One per failure mode observed:
`TargetDown`, `ScrapeSampleLimitExceeded`, `PrometheusSeriesGrowthAbnormal`
(series created per second above 10 for 10 minutes: the fingerprint of an
unbounded label), `PrometheusHeadSeriesHigh`, `PrometheusStorageNearlyFull`
(blocks plus WAL above 85% of `retentionSize`), `PrometheusScrapeTooSlow`
(large payloads are a leading indicator), `PrometheusRuleEvaluationFailures`,
`ServiceRequestRateZero` (would have fired on day one) and
`ServiceMetricCardinalityHigh` (more than 100 series for a metric that
should have 15).

**Q: Why does Alertmanager have a null receiver?**
A: The interview scope is the pipeline, not the pager. The receiver is the
one thing that is always environment specific (PagerDuty, Opsgenie, Slack).
What matters is that alerts have somewhere to go, that routing groups by
alertname and namespace, and that a tenant label can fan out per team later.

**Q: How did you verify the fix?**
A: Same measurements as the diagnosis, after the change: `count` of the
metric, `sum(rate())`, TSDB label statistics, targets, rule groups, attached
Alertmanagers, PVC bound, Grafana datasource health. Then a full teardown and
`./setup.sh` from scratch to make sure it reproduces from zero. Those checks
are now `make verify`.

**Q: What would you do differently in production?**
A: Move the guard rails out of manifests and into policy: a Kyverno or
conftest rule that rejects a Prometheus CR without limits and storage, and a
CI job that scrapes an exporter's `/metrics` and fails when any label has
more than N values. Put `prometheus_tsdb_head_series` and RSS on SLO-style
alerts owned by the platform team. Add a long-term store so local disk is no
longer a failure mode.

## 3. Multi-tenant design

**Q: Describe the architecture in one minute.**
A: One namespace per team with an operator-managed Prometheus that can only
see its own namespace. A central Prometheus federates only recording-rule
output from every tenant, discovered by a label, so a new tenant needs zero
central change. One Grafana with a datasource per tenant delivered by a
sidecar. One Alertmanager with a `tenant` label on every alert. A separate
platform Prometheus watches all of it. A tenant is a directory in git
rendered from one template.

**Q: Why the Prometheus Operator and not plain StatefulSets or Helm charts per team?**
A: It was already in the stack, and its CRDs are the self-service API:
teams write ServiceMonitor and PrometheusRule objects in their namespace,
the operator turns them into scrape and rule config, reloads, and manages
the StatefulSet and PVC. The alternative is generating prometheus.yml per
team and owning reloads and rollouts yourself. The operator is the
standard answer for "many Prometheus instances on Kubernetes".

**Q: How is a tenant isolated?**
A: Four mechanisms. The Prometheus CR uses `serviceMonitorNamespaceSelector`,
`podMonitorNamespaceSelector` and `ruleNamespaceSelector` restricted to
namespaces with `tenant: <name>`, and the object selectors require the same
label, so a team cannot scrape or load rules into another team's server. The
ServiceAccount has a namespace-scoped Role, not a ClusterRole, so the
Kubernetes API will not even list other namespaces' endpoints. Resource
limits, retention and PVC size are identical from the template. And
`externalLabels.tenant` stamps every series that leaves the instance.
Verified: team alpha's Prometheus returns `["alpha"]` for the `team` label
and lists only two targets, both in `team-alpha`.

**Q: What is federation and why use it here?**
A: `/federate` is an endpoint every Prometheus exposes that returns the
current value of series matching a selector. The central server scrapes it
like any target. It is native, needs no new component, and for the stated
requirement ("one dashboard with request rates across all teams") it is
enough. The design decision is what crosses: only series named
`level:metric:aggregation`, the recording-rule naming convention. Raw
series never leave a tenant, so a cardinality incident cannot propagate
upward. Measured: 2 to 10 samples per federation scrape per tenant.

**Q: Why recording rules as the federation contract?**
A: Three reasons. Bounded cost: the central server ingests aggregates, not
raw series. Ownership: tenants decide what they publish by writing rules in
their own namespace. Stability: the dashboard depends on a named rule, not
on the internals of a team's metrics.

**Q: What are the limits of federation?**
A: Each federation scrape is a point-in-time copy at the federation
interval, so resolution is coarse and there is no drill-down into raw tenant
data from the centre. Timestamps are the tenant's, which is fine, but
`honor_labels` must be on or the tenant's external labels get renamed. It
does not give you long-term storage, deduplication of HA pairs, or a single
query endpoint over everything. When any of those become requirements,
federation is the wrong tool.

**Q: When would you use Thanos instead?**
A: When management wants ad-hoc queries across all tenants, not just the
pre-agreed aggregates; when you need retention beyond what local disks can
hold; when Prometheus runs as HA pairs and you need deduplicated results;
or when downsampled years of history matter. Thanos adds a sidecar next to
each Prometheus that uploads blocks to object storage, a Querier that fans
out to all sidecars and stores for a single global view, a Store Gateway
for historical blocks, and a Compactor for downsampling. In this design the
tenant directory does not change; the Prometheus CR gains a `thanos:`
block. Cost: more components, object storage, and query latency that
depends on the slowest tenant.

**Q: When Mimir or Cortex instead of Thanos?**
A: When you want real multi-tenancy in the storage layer. Mimir and Cortex
are push-based: every Prometheus remote-writes with a tenant ID header, and
the backend enforces per-tenant limits (series, ingestion rate, query
concurrency), stores each tenant separately, and exposes one query
endpoint that is tenant-aware. That is the answer when the number of teams
grows past what you want to run as individual servers, or when per-tenant
quotas must be enforced centrally rather than by convention. Thanos keeps
the Prometheus-per-team model and adds a global layer; Mimir replaces the
storage of all of them with one horizontally scalable system. Operationally
Mimir is heavier: ingesters, distributors, compactors, store gateways,
queriers, rulers, and a ring to coordinate them.

**Q: And VictoriaMetrics?**
A: Same push model as Mimir with a simpler operational footprint and lower
resource usage, often chosen by smaller teams. The trade-off is PromQL
compatibility edge cases (MetricsQL) and a smaller ecosystem around
multi-tenancy features. For this repository's scale, VictoriaMetrics single
node plus vmagent would also be a defensible "step two".

**Q: Why not just one big Prometheus with a `team` label?**
A: Because the requirement was that teams run their own queries and alerts
independently. One server means one rule file, one memory budget, one
blast radius: one team's cardinality bug (exactly the task 1 incident)
takes down everyone's monitoring. Per-team instances give each team a
budget they can exhaust without affecting others.

**Q: How does Grafana learn about a new tenant?**
A: A `kiwigrid/k8s-sidecar` container watches every namespace for
ConfigMaps labelled `grafana_datasource=1`, writes them into the
provisioning directory and calls Grafana's provisioning reload API. The
tenant template includes one such ConfigMap, so onboarding creates the
datasource with no change to the Grafana deployment. An init container with
the same image runs in list mode so the first boot already sees every
tenant. The central datasource is delivered the same way, so there is one
mechanism, not two.

**Q: What went wrong with the sidecar?**
A: The first memory limit of 64Mi was too low. The container showed
Running, wrote nothing, produced no logs through kubectl, and `kubectl
exec` failed with "procReady not received (possibly OOM-killed)". Reading
the container logs through the container runtime on the node showed the
sidecar had written the files, and dmesg showed the kernel killing the
Python process. Raised the limit to 200Mi. Second issue: the reload call
fired before Grafana finished booting, so the datasources were on disk but
not loaded. Added the init container and retry settings for the reload
request.

**Q: How is alerting handled per tenant?**
A: All Prometheus instances send to one Alertmanager. Every tenant alert
carries the `tenant` external label, so routes can match on it and send
team alpha's alerts to team alpha's receiver. The `AlertmanagerConfig` CRD
lets a team manage its own routes and receivers from its own namespace
without touching the shared config. If noisy neighbours become a problem,
the same template can grow an Alertmanager per tenant.

**Q: Why did the operator need extra CRDs?**
A: The repository shipped six CRDs but not `AlertmanagerConfig` or
`ThanosRuler`. The operator's Alertmanager controller waits for its informer
cache to sync on `AlertmanagerConfig`, and without the CRD that never
completes, so the Alertmanager CR was silently never reconciled. The
missing `ThanosRuler` CRD produced a constant error loop in the operator
log. Both were added from the matching operator release.

## 4. Tenant automation

**Q: How is a new tenant added?**
A: `scripts/add-tenant.sh foxtrot` renders `k8s/tenants/foxtrot/` from
`k8s/tenants/_template/` by replacing the `TENANT` token, and regenerates
the aggregate kustomization. That directory is committed in a pull request.
CI runs `kustomize build`, schema validation and policy checks. After
merge, an Argo CD ApplicationSet with a directory generator over
`k8s/tenants/*` syncs it. The operator creates the Prometheus, the central
server discovers the federation Service by label, the Grafana sidecar
picks up the datasource. Measured locally with `--apply`: about 90 seconds
from command to federated target up and datasource visible.

**Q: Why a `sed` template and Kustomize rather than Helm?**
A: Zero new dependencies and the output is plain YAML a reviewer can read
in the PR. Kustomize handles aggregation and `kubectl apply -k` is built
in. Helm is the right step up once tenants need divergent values (bigger
budgets, extra scrape targets, different retention); then `helm template`
replaces `sed` and the rendered directory stays the artefact that is
committed.

**Q: Why Argo CD ApplicationSet specifically?**
A: The directory generator maps "one directory per tenant" to "one
Application per tenant" without any per-tenant Argo configuration. You get
sync on merge, pruning on delete, drift detection, and an audit trail per
tenant for free. Flux Kustomization with a similar layout would work too.

**Q: How is a tenant removed?**
A: `git rm -r k8s/tenants/foxtrot`, regenerate the aggregate, merge. Argo
CD prunes the namespace, which deletes the Prometheus, PVC and datasource
ConfigMap; the sidecar removes the datasource; the central server drops
the target. Locally `make remove-tenant TEAM=foxtrot` does the same.

**Q: What CI gates would you require on a tenant PR?**
A: `kustomize build` for syntax, `kubeconform` with the operator CRD
schemas for structure, and a policy check (Kyverno or conftest) asserting
limits, storage, `enforcedSampleLimit`, and that selectors carry the
tenant label. The point is that the guard rails from the incident are
mandatory, not a convention.

**Q: What breaks first when you go from 5 tenants to 50?**
A: Node resources first: each tenant is 256Mi to 512Mi plus a PVC, so
capacity planning and per-namespace ResourceQuotas come before anything
else. Then the central server's federation scrape fan-out (50 targets every
30 s is fine, but each new recording rule multiplies). Then Grafana's
datasource list becomes unusable without folders and team permissions.
Around that size the push model (Mimir) starts to pay for itself.

## 5. Meta-monitoring

**Q: Who monitors the monitoring?**
A: A third Prometheus, `platform`, in the `monitoring` namespace. It
scrapes the operator, Grafana, Alertmanager, the central Prometheus and
every tenant Prometheus, selecting only `tier: meta` objects. It alerts on
any Prometheus down or above 85% of its memory limit, abnormal series
growth anywhere in the fleet, operator reconcile errors, Alertmanager down,
Grafana down, Grafana 5xx ratio and latency, and datasource errors.

**Q: Why a separate instance instead of the central Prometheus?**
A: If the central Prometheus is OOM-killed again, the thing that alerts on
it must not be the thing that died. Separate failure domain, separate
resource budget, and it scrapes `/metrics` on the tenants rather than
`/federate`, so it sees their health rather than their aggregates.

**Q: And who monitors the platform Prometheus?**
A: In this repository, nothing, and I would say so. The standard answer is
a dead man's switch: a `Watchdog` alert that always fires, routed to an
external heartbeat service (Healthchecks.io, PagerDuty heartbeat, Opsgenie
heartbeat). If the heartbeat stops arriving, the external service pages.
That is the one alert you cannot host inside the stack.

**Q: What does the Grafana Health dashboard tell you that the platform dashboard does not?**
A: Request rate by status code, latency percentiles and the slowest
handlers show whether Grafana itself is the problem. The datasource proxy
panels show request rate, latency and response size per datasource, so one
slow tenant Prometheus appears as one line rather than as "Grafana is slow".
Metric names were verified against the running Grafana's `/metrics` before
the panels were written.

## 6. Prometheus fundamentals that come up

**Q: `rate` versus `irate` versus `increase`?**
A: `rate` is the per-second average over the range, extrapolated to the
window edges; use it for alerts and dashboards. `irate` uses only the last
two samples, so it is spiky and only for fast-moving graphs. `increase` is
`rate` multiplied by the window length. All three handle counter resets.
The range must cover at least two scrapes, so with a 15 s interval a `[1m]`
window is the practical minimum and `[5m]` is the safe default.

**Q: How does `histogram_quantile` work and why `sum by (le)`?**
A: Buckets are cumulative counters labelled `le`. `histogram_quantile`
interpolates within the bucket where the target quantile falls, so the
answer is only as precise as the bucket boundaries. You must aggregate
buckets with `sum by (le, ...)` before calling it; averaging quantiles
across instances is wrong, aggregating buckets is right.

**Q: What is the recording rule naming convention?**
A: `level:metric:operations`, for example
`team_service:service_request:rate5m`. Level is the aggregation labels
kept, metric is the source metric, operations describe what was done.
This repository uses that convention as the federation filter.

**Q: Explain the head block, WAL, blocks and compaction.**
A: New samples go into the in-memory head and are appended to the WAL for
crash recovery. Every two hours the head is cut into an immutable block on
disk with its own index. Compaction merges small blocks into larger ones
and applies retention. Memory is dominated by the head (active series);
disk by blocks plus the WAL. `retentionSize` applies to blocks only.

**Q: What is staleness and why does it matter for alerts?**
A: When a series stops being scraped, Prometheus writes a staleness marker
and the series disappears from instant queries after five minutes. That is
why `absent()` exists, why `ServiceRequestRateZero` uses
`== 0 or absent(...)`, and why a target that vanishes does not keep its
last value forever.

**Q: Symptom alerts versus cause alerts?**
A: Page on symptoms users feel (error rate, latency, no traffic). Alert on
causes as warnings for context (series growth, disk nearly full). `for`
durations avoid paging on single-scrape blips. In this repository
`ServiceRequestRateZero` is the symptom; `PrometheusSeriesGrowthAbnormal` is
the cause that would have explained it.

## 7. Operations and tooling

**Q: Why a Makefile and what does the preflight do?**
A: One entry point for humans: `make status`, `make debug`, `make verify`,
`make add-tenant TEAM=x`. Every cluster-touching target first checks that
the tools exist, Docker is running, the kind cluster exists, the kubeconfig
context exists and the API server answers, then that the stack is deployed
and reachable on localhost. Each failure prints the command that fixes it.
This came directly from running `make apply` on a machine without the
cluster and getting eight kubectl stack traces about `localhost:8080`.

**Q: Why pin `kubectl --context kind-sre-challenge`?**
A: So that `make apply` can never hit whatever cluster happens to be the
current context. A production kubeconfig on the same laptop is the obvious
risk.

**Q: What did `make lint` catch?**
A: The original `k8s/prometheus-operator/kustomization.yaml` referenced
files outside its directory, which kustomize rejects for security. Nobody
had noticed because `setup.sh` applies files individually. Each directory
now has its own kustomization and every root builds.

## 8. Process and git

**Q: How is the repository organised for maintainers?**
A: `main` receives only release pull requests from `develop`; `develop`
receives one pull request per `feature/*`, `fix/*`, `docs/*` (and similar)
branch. Both are protected: no direct pushes, no force pushes, required
`branch-policy` and `lint` checks, signed commits, admins included. A GitHub
Actions job enforces the source-branch rule because branch protection
cannot express "only from develop". Feature branches are kept after merge
so the PR history stays navigable.

**Q: Why signed commits?**
A: Authorship you can verify. Merge commits created by GitHub are signed
with GitHub's key and show as verified; everything else is signed with the
author's key.

**Q: What surprised you during the work?**
A: Four things. The missing `AlertmanagerConfig` CRD silently blocked
Alertmanager reconciliation. The Grafana sidecar at 64Mi ran, wrote files,
and still could not be inspected because exec itself was OOM-killed.
Grafana loads datasource provisioning at boot, so a sidecar that writes
after boot needs the reload API and retries. And `retentionSize` not
counting the WAL is the kind of detail that only shows up when you read
the documentation after the disk is already full.

**Q: If you had one more day?**
A: Thanos sidecar plus Querier to replace federation for ad-hoc queries,
a Watchdog heartbeat to an external service, ResourceQuota per tenant
namespace, dashboards delivered by the same sidecar pattern as datasources,
and a Kyverno policy that makes the Prometheus CR limits mandatory.
