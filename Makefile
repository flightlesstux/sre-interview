# Operator controls for the SRE challenge stack.
# Run `make` or `make help` for the list of targets.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

CLUSTER      ?= sre-challenge
NS           ?= sre-challenge
TEAM         ?=
PROM_URL     ?= http://localhost:9090
GRAFANA_URL  ?= http://localhost:3000
AM_URL       ?= http://localhost:9093
PLATFORM_URL ?= http://localhost:9091
GRAFANA_AUTH ?= admin:admin
TENANT_PORT  ?= 19090

TENANT_DIRS  := $(sort $(filter-out _template,$(notdir $(shell find k8s/tenants -mindepth 1 -maxdepth 1 -type d))))

define need_team
	@if [ -z "$(TEAM)" ]; then echo "usage: make $@ TEAM=<name>"; exit 2; fi
endef

##@ Lifecycle

.PHONY: setup
setup: ## Create the kind cluster and deploy the full stack (./setup.sh)
	./setup.sh

.PHONY: teardown
teardown: ## Delete the kind cluster (./teardown.sh)
	./teardown.sh

.PHONY: build
build: ## Rebuild mock-service, load into kind, restart every mock-service deployment
	docker build -t mock-service:latest app/
	kind load docker-image mock-service:latest --name $(CLUSTER)
	@for ns in $$(kubectl get deploy -A -l app=mock-service -o jsonpath='{.items[*].metadata.namespace}'); do \
		kubectl rollout restart deployment/mock-service -n $$ns; \
	done

.PHONY: apply
apply: ## Re-apply platform manifests and all tenants (no cluster recreation)
	for crd in k8s/infra/crds/*.yaml; do kubectl apply --server-side -f $$crd >/dev/null; done
	kubectl apply -k k8s/infra
	kubectl apply -f k8s/base/
	kubectl apply -f k8s/prometheus-operator/rbac.yaml -f k8s/prometheus-operator/alertmanager.yaml \
		-f k8s/prometheus-operator/prometheus.yaml -f k8s/prometheus-operator/servicemonitor.yaml \
		-f k8s/prometheus-operator/rules.yaml -f k8s/prometheus-operator/federation.yaml
	kubectl apply -k k8s/tenants

.PHONY: lint
lint: ## Validate shell scripts and kustomize builds
	bash -n setup.sh teardown.sh scripts/add-tenant.sh
	kubectl kustomize k8s/prometheus-operator >/dev/null && echo "k8s/prometheus-operator: ok"
	kubectl kustomize k8s/tenants >/dev/null && echo "k8s/tenants: ok"
	@for d in $(TENANT_DIRS); do \
		if grep -q TENANT k8s/tenants/$$d/*.yaml; then echo "k8s/tenants/$$d: unrendered TENANT placeholder"; exit 1; fi; \
	done; echo "tenants rendered: $(TENANT_DIRS)"

##@ Status and debugging

.PHONY: status
status: ## Pods, Prometheus CRs, PVCs, federation targets, firing alerts
	@echo "== pods (non kube-system)"; kubectl get pods -A --no-headers | grep -vE '^(kube-system|local-path-storage)' || true
	@echo; echo "== prometheus and alertmanager CRs"; kubectl get prometheus,alertmanager -A
	@echo; echo "== persistent volumes"; kubectl get pvc -A --no-headers | awk '{printf "%-16s %-48s %-8s %s\n",$$1,$$2,$$3,$$5}'
	@echo; echo "== federation targets (central)"
	@curl -sf $(PROM_URL)/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="federate") | "\(.labels.tenant_namespace)\t\(.health)"' || echo "central Prometheus not reachable at $(PROM_URL)"
	@echo; echo "== platform (meta) targets"
	@curl -sf $(PLATFORM_URL)/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.labels.namespace)\t\(.health)"' | sort | column -t -s $$'\t' || echo "platform Prometheus not reachable at $(PLATFORM_URL)"
	@echo; echo "== firing alerts (central)"
	@curl -sf $(AM_URL)/api/v2/alerts | jq -r 'if length==0 then "none" else .[] | "\(.labels.alertname)\t\(.labels.severity)\t\(.labels.tenant // "platform")" end' || echo "Alertmanager not reachable at $(AM_URL)"

.PHONY: debug
debug: ## Pods not running, recent warning events, operator errors, failing pod details
	@echo "== pods not Running/Completed"
	@kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || echo "none"
	@echo; echo "== warning events (last 30)"
	@kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,NS:.metadata.namespace,OBJECT:.involvedObject.name,REASON:.reason,MSG:.message --no-headers 2>/dev/null | tail -30 || true
	@echo; echo "== operator errors (last 20)"
	@kubectl logs deployment/prometheus-operator -n monitoring --since=30m 2>/dev/null | grep -iE 'level=(error|warn)' | tail -20 || echo "no operator logs"
	@echo; echo "== describe of non-ready pods"
	@kubectl get pods -A --no-headers | grep -vE 'Running|Completed' | awk '{print $$1, $$2}' | while read ns pod; do \
		echo "--- $$ns/$$pod"; kubectl describe pod $$pod -n $$ns | sed -n '/^Events:/,$$p'; done || true

.PHONY: verify
verify: ## Check the task 1 fix and task 2 federation against the live stack
	@echo "== task 1"
	@printf 'service_request_total series (expect 15): '; curl -sf -G $(PROM_URL)/api/v1/query --data-urlencode 'query=count(service_request_total)' | jq -r '.data.result[0].value[1] // "n/a"'
	@printf 'request rate (expect > 0):                 '; curl -sf -G $(PROM_URL)/api/v1/query --data-urlencode 'query=sum(rate(service_request_total[5m]))' | jq -r '.data.result[0].value[1] // "n/a"'
	@printf 'label with most values:                    '; curl -sf $(PROM_URL)/api/v1/status/tsdb | jq -r '.data.labelValueCountByLabelName[0] | "\(.name)=\(.value)"'
	@printf 'rule groups loaded:                        '; curl -sf $(PROM_URL)/api/v1/rules | jq -r '[.data.groups[].name] | join(", ")'
	@printf 'alertmanagers attached:                    '; curl -sf $(PROM_URL)/api/v1/alertmanagers | jq -r '.data.activeAlertmanagers | length'
	@echo; echo "== task 2"
	@echo "request rate per tenant (federated):"
	@curl -sf -G $(PROM_URL)/api/v1/query --data-urlencode 'query=sum by (tenant) (team:service_request:rate5m{tenant!=""})' | jq -r '.data.result[] | "  \(.metric.tenant)\t\(.value[1])"'
	@echo "active series per tenant:"
	@curl -sf -G $(PROM_URL)/api/v1/query --data-urlencode 'query=team:prometheus_tsdb_head_series:sum{tenant!=""}' | jq -r '.data.result[] | "  \(.metric.tenant)\t\(.value[1])"'
	@printf 'grafana datasources: '; curl -sf -u $(GRAFANA_AUTH) $(GRAFANA_URL)/api/datasources | jq -r '[.[].name] | join(", ")'

.PHONY: logs-operator
logs-operator: ## Follow Prometheus Operator logs
	kubectl logs -f deployment/prometheus-operator -n monitoring

.PHONY: logs-prometheus
logs-prometheus: ## Follow central Prometheus logs
	kubectl logs -f statefulset/prometheus-prometheus -n $(NS) -c prometheus

.PHONY: logs-app
logs-app: ## Follow the central mock-service logs
	kubectl logs -f deployment/mock-service -n $(NS)

.PHONY: logs-grafana
logs-grafana: ## Follow Grafana and its datasource sidecar
	kubectl logs -f deployment/grafana -n $(NS) --all-containers

.PHONY: logs-platform
logs-platform: ## Follow the platform (meta-monitoring) Prometheus logs
	kubectl logs -f statefulset/prometheus-platform -n monitoring -c prometheus

.PHONY: targets
targets: ## All scrape targets of the central Prometheus with health
	@curl -sf $(PROM_URL)/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.labels.namespace // .labels.tenant_namespace)\t\(.health)\t\(.lastError)"' | column -t -s $$'\t'

.PHONY: alerts
alerts: ## Alerts known to the central Prometheus (pending and firing)
	@curl -sf $(PROM_URL)/api/v1/alerts | jq -r '.data.alerts[] | "\(.state)\t\(.labels.alertname)\t\(.labels.severity)"' | column -t -s $$'\t' || echo "none"

##@ Tenants

.PHONY: tenants
tenants: ## List rendered tenants and their Prometheus status
	@echo "rendered: $(TENANT_DIRS)"
	@kubectl get prometheus -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.availableReplicas,RECONCILED:'.status.conditions[?(@.type=="Reconciled")].status' 2>/dev/null || true

.PHONY: render-tenant
render-tenant: ## Render k8s/tenants/$(TEAM) from the template (TEAM=name)
	$(need_team)
	scripts/add-tenant.sh $(TEAM)

.PHONY: add-tenant
add-tenant: ## Render and apply a tenant, wait for its Prometheus (TEAM=name)
	$(need_team)
	scripts/add-tenant.sh $(TEAM) --apply

.PHONY: remove-tenant
remove-tenant: ## Delete a tenant's namespace and rendered directory (TEAM=name)
	$(need_team)
	kubectl delete namespace team-$(TEAM) --ignore-not-found
	rm -rf k8s/tenants/$(TEAM)
	@for d in $(filter-out $(TEAM),$(TENANT_DIRS)); do scripts/add-tenant.sh $$d >/dev/null; done
	@echo "removed tenant $(TEAM); aggregate kustomization regenerated"

.PHONY: pf-tenant
pf-tenant: ## Port-forward a tenant Prometheus to localhost:$(TENANT_PORT) (TEAM=name)
	$(need_team)
	@echo "http://localhost:$(TENANT_PORT)  (team-$(TEAM))"
	kubectl port-forward -n team-$(TEAM) svc/prometheus $(TENANT_PORT):9090

.PHONY: tenant-check
tenant-check: ## Show what a tenant Prometheus can see: team values and targets (TEAM=name)
	$(need_team)
	@kubectl port-forward -n team-$(TEAM) svc/prometheus $(TENANT_PORT):9090 >/dev/null 2>&1 & pid=$$!; sleep 2; \
		printf 'team label values: '; curl -sf localhost:$(TENANT_PORT)/api/v1/label/team/values | jq -c '.data'; \
		printf 'targets:           '; curl -sf localhost:$(TENANT_PORT)/api/v1/targets | jq -c '[.data.activeTargets[] | "\(.labels.job)@\(.labels.namespace):\(.health)"]'; \
		printf 'rule groups:       '; curl -sf localhost:$(TENANT_PORT)/api/v1/rules | jq -c '[.data.groups[].name]'; \
		kill $$pid

##@ Shortcuts

.PHONY: open
open: ## Open Grafana, Prometheus and Alertmanager in the browser (macOS)
	open $(GRAFANA_URL) $(PROM_URL) $(AM_URL) $(PLATFORM_URL)

.PHONY: urls
urls: ## Print the access URLs
	@echo "Grafana       $(GRAFANA_URL)  (admin/admin)"
	@echo "Prometheus    $(PROM_URL)"
	@echo "Alertmanager  $(AM_URL)"
	@echo "Platform Prom $(PLATFORM_URL)  (meta-monitoring: operator, Grafana, all Prometheus)"
	@echo "mock-service  http://localhost:8080/metrics"

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make <target> [TEAM=name]\n"} \
		/^##@/ { printf "\n%s\n", substr($$0, 5) } \
		/^[a-zA-Z_-]+:.*?##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
