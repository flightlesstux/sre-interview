# SRE Interview

## Scenario

You joined the platform team 2 weeks ago. The on-call rotation has been quiet — no pages, no fire drills. The Grafana dashboard in the "Service Overview" panel looks perfectly healthy.

And yet... a senior engineer mentioned in standup that the Prometheus server ran out of disk again last night. The infra team says the Prometheus container was OOM-killed twice this week.

Second, each team (alpha, bravo, charlie, delta, echo) wants their own Prometheus so they can run their own queries and alerts independently and management still needs a single dashboard showing request rates across all teams.

## Tasks

1. Identify and fix the issue with the current monitoring stack
2. Design and implement a solution to provide automated monitoring tenant management and federated queries across all stacks. How will a new tenant will be added, which tools would you use to automate it, how would the flow look like 


The goal is to understand your thought process, not develop a production-ready solution.
You can use any tools or technologies you're comfortable with, if something look to complex to implement in the time given, just explain your design and how you would implement it.

The solution will be presented in the on-site interview, so be prepared to explain your findings with any supporting design document, diagram or script demos.

---

## Prerequisites

Install these before starting:

- [Docker](https://docs.docker.com/get-docker/)
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
4. Deploy the app, Grafana, Prometheus, and ServiceMonitor
5. Wait for everything to be ready

**Access endpoints after setup:**

| Service | URL |
|---------|-----|
| Mock Service /metrics | http://localhost:8080/metrics |
| Grafana Dashboard | http://localhost:3000 (admin/admin) |
| Prometheus | http://localhost:9090 |

**Tear down when done:**

```bash
./teardown.sh
```

---

## Submission

When you're done,you can push your solution to this repository.
