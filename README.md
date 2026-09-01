# SRE Interview

## Scenario

You joined the platform team 2 weeks ago. The on-call rotation has been quiet: no pages, no fire drills. The Grafana dashboard in the "Service Overview" panel looks perfectly healthy.

And yet, a senior engineer mentioned in standup that the Prometheus server ran out of disk again last night. The infra team says the Prometheus container was OOM-killed twice this week.

Second, each team (alpha, bravo, charlie, delta, echo) wants their own Prometheus so they can run their own queries and alerts independently, and management still needs a single dashboard showing request rates across all teams.

## Tasks

1. Identify and fix the issue with the current monitoring stack
2. Design and implement a solution to provide automated monitoring tenant management and federated queries across all stacks. How will a new tenant be added, which tools would you use to automate it, how would the flow look like

The goal is to understand your thought process, not develop a production-ready solution.

---

## Solution

| Task | Document | Summary |
|------|----------|---------|
| 1 | [docs/01-incident-analysis.md](docs/01-incident-analysis.md) | `service_request_total` had a per-request UUID label. Removed it, added scrape limits, persistent storage, self-monitoring, alerting, and a dashboard that shows Prometheus health. |
| 2 | [docs/02-multi-tenant-design.md](docs/02-multi-tenant-design.md) | One operator-managed Prometheus per team namespace, recording rules federated into a central Prometheus, Grafana datasource per tenant via sidecar, tenant onboarding with `scripts/add-tenant.sh`. |

Presentation walkthrough for the on-site: open [docs/presentation.html](docs/presentation.html) in a browser.

Repository layout after the changes:

```
app/                          mock-service (TEAM env pins an instance to a tenant)
k8s/infra/                    Prometheus Operator and CRDs
k8s/base/                     Grafana (with datasource sidecar), legacy mock-service
k8s/prometheus-operator/      central Prometheus, Alertmanager, rules, federation
k8s/tenants/_template/        the tenant template (edit this)
k8s/tenants/<team>/           rendered tenants, one directory each
scripts/add-tenant.sh         render and optionally apply a tenant
docs/                         analysis and design documents
```

### Adding a tenant

```bash
scripts/add-tenant.sh foxtrot            # render k8s/tenants/foxtrot, commit it in a PR
scripts/add-tenant.sh foxtrot --apply    # same, and apply to the current cluster
```

Within about a minute the new team has its own Prometheus, its own rules, a datasource in Grafana and a line on the "Global Overview - All Tenants" dashboard.

---

## Prerequisites

Install these before starting:

- [Docker](https://docs.docker.com/get-docker/) (the full stack with five tenants needs roughly 4 GB of memory for the kind node)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

---

## Spin Up Everything

One command to create the kind cluster, build the app, and deploy the full stack:

```bash
./setup.sh
```

This will:
1. Create a kind cluster named `sre-challenge`
2. Build and load the `mock-service` container image into the cluster
3. Install the Prometheus Operator CRDs and controller
4. Deploy the app, Grafana, central Prometheus, Alertmanager, rules and the federation ServiceMonitor
5. Deploy every tenant under `k8s/tenants/`
6. Wait for everything to be ready

**Access endpoints after setup:**

| Service | URL |
|---------|-----|
| Mock Service /metrics | http://localhost:8080/metrics |
| Grafana | http://localhost:3000 (admin/admin) |
| Central Prometheus | http://localhost:9090 |
| Alertmanager | http://localhost:9093 |
| Tenant Prometheus | `kubectl port-forward -n team-alpha svc/prometheus 19090:9090` |

Grafana dashboards: "Service Overview - SRE Challenge" (central stack and Prometheus health) and "Global Overview - All Tenants" (federated view).

**Tear down when done:**

```bash
./teardown.sh
```
