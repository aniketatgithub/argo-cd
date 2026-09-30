#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="argocd-mtls"
NAMESPACE="argocd"

echo "==> Cleaning verification Jobs..."
kubectl -n "${NAMESPACE}" delete job mtls-probe-no-cert mtls-probe-with-cert 2>/dev/null || true

echo "==> Optionally delete the k3d cluster (uncomment to enable)"
k3d cluster delete "${CLUSTER_NAME}" || true

echo "==> To remove generated certs: rm -rf scripts/mtls/certs"
echo "Done."
