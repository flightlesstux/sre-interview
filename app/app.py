import random
import time
import threading
import uuid
from prometheus_client import Counter, start_http_server

SERVICES = ["auth", "payments", "inventory"]
TEAMS = ["alpha", "bravo", "charlie", "delta", "echo"]

request_total = Counter(
    "service_request_total",
    "Total requests processed",
    ["service", "team", "request_id"],
)


def simulate_requests():
    while True:
        service = random.choice(SERVICES)
        team = random.choice(TEAMS)
        request_id = str(uuid.uuid4())

        request_total.labels(
            service=service, team=team, request_id=request_id
        ).inc()

        time.sleep(max(0.01, 0.15 + random.gauss(0, 0.03)))


def main():
    start_http_server(8080)
    print("App started on :8080/metrics")

    threads = []
    for _ in range(5):
        t = threading.Thread(target=simulate_requests, daemon=True)
        t.start()
        threads.append(t)

    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
