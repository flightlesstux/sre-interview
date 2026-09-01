#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sre-challenge"

echo "Destroying kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "$CLUSTER_NAME"
echo "Done."
