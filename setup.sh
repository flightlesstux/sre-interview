#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="sre-challenge"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

check_prerequisites() {
  log "Checking prerequisites..."
  for cmd in docker kind kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
      err "$cmd is not installed. Please install it first."
      exit 1
    fi
  done
}

create_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Kind cluster '${CLUSTER_NAME}' already exists. Skipping creation."
    return
  fi

  log "Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "${SCRIPT_DIR}/kind-config.yaml"

  log "Waiting for control plane to be ready..."
  kubectl wait --for=condition=Ready node/${CLUSTER_NAME}-control-plane --timeout=120s
}

build_and_load_app() {
  log "Building mock-service Docker image..."
  docker build -t mock-service:latest "${SCRIPT_DIR}/app/"

  log "Loading image into kind cluster..."
  kind load docker-image mock-service:latest --name "$CLUSTER_NAME"
}

deploy_crds() {
  log "Installing Prometheus Operator CRDs..."
  for crd in "${SCRIPT_DIR}"/k8s/infra/crds/*.yaml; do
    kubectl apply --server-side -f "$crd"
  done
}

deploy_operator() {
  log "Deploying Prometheus Operator..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/infra/namespace.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/infra/operator.yaml"

  log "Waiting for prometheus-operator to be ready..."
  kubectl wait --for=condition=Available deployment/prometheus-operator \
    -n monitoring --timeout=120s
}

deploy_all() {
  log "Deploying app and monitoring stack..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/base/namespace.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/base/app.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/base/grafana-datasources.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/base/grafana-dashboard-provisioning.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/base/grafana-dashboard.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/base/grafana.yaml"

  log "Deploying Prometheus, ServiceMonitor, RBAC, and alerts..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/prometheus-operator/rbac.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/prometheus-operator/prometheus.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/prometheus-operator/servicemonitor.yaml"
}

wait_for_ready() {
  log "Waiting for mock-service to be ready..."
  kubectl wait --for=condition=Available deployment/mock-service \
    -n sre-challenge --timeout=120s

  log "Waiting for Grafana to be ready..."
  kubectl wait --for=condition=Available deployment/grafana \
    -n sre-challenge --timeout=120s

  log "Waiting for Prometheus StatefulSet..."
  kubectl rollout status statefulset/prometheus-prometheus \
    -n sre-challenge --timeout=180s 2>/dev/null || \
    warn "Prometheus StatefulSet not ready yet (may take a minute)."
}

print_access_info() {
  echo ""
  echo "=========================================="
  echo -e "${GREEN}  SRE Challenge is ready!${NC}"
  echo "=========================================="
  echo ""
  echo "  Access endpoints (via kind NodePort):"
  echo ""
  echo "    Mock Service /metrics : http://localhost:8080/metrics"
  echo "    Grafana Dashboard     : http://localhost:3000 (admin/admin)"
  echo "    Prometheus            : http://localhost:9090"
  echo ""
  echo "  Useful commands:"
  echo ""
  echo "    kubectl get pods -n sre-challenge"
  echo "    kubectl get prometheus -n sre-challenge"
  echo "    kubectl get servicemonitor -n sre-challenge"
  echo "    kubectl logs -f deployment/mock-service -n sre-challenge"
  echo ""
  echo "  To tear down:"
  echo ""
  echo "    ./teardown.sh"
  echo ""
  echo "=========================================="
}

main() {
  check_prerequisites
  create_cluster
  build_and_load_app
  deploy_crds
  deploy_operator
  deploy_all
  wait_for_ready
  print_access_info
}

main "$@"
