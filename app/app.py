import os
import random
import time
import threading
from prometheus_client import Counter, Histogram, start_http_server

SERVICES = ["auth", "payments", "inventory"]
TEAMS = ["alpha", "bravo", "charlie", "delta", "echo"]

# TEAM pins this instance to a single tenant. Unset means the legacy
# behaviour: one instance emitting traffic for every team.
TEAM = os.environ.get("TEAM")

# Label values must be bounded. Per-request identifiers (request_id,
# user_id, trace_id, ...) belong in logs or traces, never in metric labels.
request_total = Counter(
    "service_request_total",
    "Total requests processed",
    ["service", "team"],
)

request_duration = Histogram(
    "service_request_duration_seconds",
    "Simulated request latency",
    ["service", "team"],
    buckets=(0.05, 0.1, 0.2, 0.5, 1.0),
)


def simulate_requests():
    while True:
        service = random.choice(SERVICES)
        team = TEAM or random.choice(TEAMS)
        latency = max(0.01, 0.15 + random.gauss(0, 0.03))

        request_total.labels(service=service, team=team).inc()
        request_duration.labels(service=service, team=team).observe(latency)

        time.sleep(latency)


def main():
    start_http_server(8080)
    print(f"App started on :8080/metrics (team={TEAM or 'all'})")

    threads = []
    for _ in range(5):
        t = threading.Thread(target=simulate_requests, daemon=True)
        t.start()
        threads.append(t)

    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
