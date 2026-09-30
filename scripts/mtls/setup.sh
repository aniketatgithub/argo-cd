#!/usr/bin/env bash
# setup.sh — Provision a k3d cluster and install Argo CD with optional mTLS support.
#
# This script creates an argocd-mtls cluster, installs Argo CD, and optionally
# generates mTLS certificates and configures repo-server mTLS authentication.
#
# Usage:
#   ./setup.sh                                      # uses defaults (mTLS enabled)
#   ARGOCD_VERSION=v3.5.0 ./setup.sh              # specific released version
#   ARGOCD_IMAGE=localhost:5000/argocd:dev ./setup.sh  # locally-built image
#   ENABLE_MTLS=false ./setup.sh                  # install without mTLS
#   ENABLE_MTLS=true ARGOCD_IMAGE=... ./setup.sh  # combine options
#
# Environment Variables:
#   ARGOCD_VERSION  - Argo CD version to install (default: v3.5.0)
#   ARGOCD_IMAGE    - Local image to use (takes precedence over ARGOCD_VERSION)
#   CLUSTER_NAME    - k3d cluster name (default: argocd-mtls)
#   ENABLE_MTLS     - Enable mTLS setup (default: true, set to false to disable)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.0-rc1}"
ARGOCD_IMAGE="${ARGOCD_IMAGE:-}"          # e.g. localhost:5000/argocd:dev
CLUSTER_NAME="${CLUSTER_NAME:-argocd-mtls}"
ARGOCD_NS="argocd"
ENABLE_MTLS="${ENABLE_MTLS:-true}"        # Enable mTLS: true or false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Normalize ENABLE_MTLS to lowercase
ENABLE_MTLS=$(echo "${ENABLE_MTLS}" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
echo "==> Checking required tools..."
for tool in docker k3d kubectl openssl; do
  if ! command -v "${tool}" &>/dev/null; then
    echo "ERROR: '${tool}' not found in PATH. Please install it first."
    echo "   k3d:     https://k3d.io/#installation"
    echo "   kubectl: https://kubernetes.io/docs/tasks/tools/"
    echo "   openssl: included with most systems"
    exit 1
  fi
done
echo "    docker, k3d, kubectl, openssl — all found."

# ---------------------------------------------------------------------------
# Determine which image / manifests to use
# ---------------------------------------------------------------------------
if [[ -n "${ARGOCD_IMAGE}" ]]; then
  echo ""
  echo "==> Using locally-built image: ${ARGOCD_IMAGE}"
  INSTALL_MODE="local-image"

  # Build the image if it doesn't exist locally
  if ! docker image inspect "${ARGOCD_IMAGE}" &>/dev/null; then
    echo ""
    echo "==> Building Argo CD image from source..."
    # Determine the repo root (2 levels up from scripts/mtls)
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

    if [[ ! -f "${REPO_ROOT}/Dockerfile" ]]; then
      echo "ERROR: Cannot find Dockerfile at ${REPO_ROOT}/Dockerfile"
      echo "Make sure you're running this from the argo-cd repository root."
      exit 1
    fi

    # Build the image
    docker build -t "${ARGOCD_IMAGE}" "${REPO_ROOT}" || {
      echo "ERROR: Failed to build image ${ARGOCD_IMAGE}"
      exit 1
    }
    echo "    Image built successfully: ${ARGOCD_IMAGE}"
  else
    echo "    Image already exists locally: ${ARGOCD_IMAGE}"
  fi
else
  echo ""
  echo "==> Using released Argo CD version: ${ARGOCD_VERSION}"
  INSTALL_MODE="release"
fi

# ---------------------------------------------------------------------------
# Create k3d cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating k3d cluster: ${CLUSTER_NAME}..."

k3d cluster create "${CLUSTER_NAME}" \
  --no-lb \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default
kubectl config use-context "k3d-${CLUSTER_NAME}"
echo "    Cluster ready. Context: k3d-${CLUSTER_NAME}"

# If using local image, import it into k3d
if [[ "${INSTALL_MODE}" == "local-image" ]]; then
  echo ""
  echo "==> Importing local image into k3d cluster..."
  k3d image import "${ARGOCD_IMAGE}" -c "${CLUSTER_NAME}" --keep-tarball

  # Verify the image is available in the cluster
  echo "==> Verifying image is available in cluster..."
  if k3d image list -c "${CLUSTER_NAME}" | grep -q "${ARGOCD_IMAGE}"; then
    echo "    ✓ Image successfully imported: ${ARGOCD_IMAGE}"
  else
    echo "WARNING: Image may not be visible in k3d image list, but should still be available."
  fi
fi

# ---------------------------------------------------------------------------
# Install Argo CD
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating namespace ${ARGOCD_NS}..."
kubectl create namespace "${ARGOCD_NS}" 2>/dev/null || true

if [[ "${INSTALL_MODE}" == "release" ]]; then
  MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  echo "==> Installing Argo CD from upstream manifests (${ARGOCD_VERSION})..."
  kubectl apply -n "${ARGOCD_NS}" -f "${MANIFEST_URL}" --server-side
else
  # Use local manifests from the codebase (includes mTLS volumes), then patch the image
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  MANIFEST_PATH="${REPO_ROOT}/manifests/install.yaml"

  if [[ ! -f "${MANIFEST_PATH}" ]]; then
    echo "ERROR: Cannot find manifests at ${MANIFEST_PATH}"
    exit 1
  fi

  echo "==> Installing Argo CD from local codebase manifests with local image override..."
  kubectl apply -n "${ARGOCD_NS}" -f "${MANIFEST_PATH}" --server-side

  echo "==> Patching Argo CD deployments to use local image: ${ARGOCD_IMAGE}"
  sleep 2

  for deploy in argocd-server argocd-repo-server argocd-application-controller \
                argocd-applicationset-controller argocd-dex-server argocd-notifications-controller; do
    echo "    Patching deployment/${deploy}..."
    kubectl patch deployment "${deploy}" -n "${ARGOCD_NS}" \
      --type='json' \
      -p="[
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${ARGOCD_IMAGE}\"},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"Never\"}
      ]" \
      2>/dev/null || true
  done

  echo "    Patching statefulset/argocd-application-controller..."
  kubectl patch statefulset argocd-application-controller -n "${ARGOCD_NS}" \
    --type='json' \
    -p="[
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${ARGOCD_IMAGE}\"},
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"Never\"}
    ]" \
    2>/dev/null || true
fi

echo ""
echo "==> Waiting for Argo CD server to be ready (up to 3 min)..."
kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NS}" --timeout=180s
kubectl rollout status deployment/argocd-repo-server \
  -n "${ARGOCD_NS}" --timeout=180s

# ---------------------------------------------------------------------------
# Generate mTLS certificates and create Secret (if enabled)
# ---------------------------------------------------------------------------
if [[ "${ENABLE_MTLS}" == "true" ]]; then
  echo ""
  echo "==> Generating mTLS certificates..."
  "${SCRIPT_DIR}/gencerts.sh"

  # ---------------------------------------------------------------------------
  # Create argocd-repo-server-mtls Secret
  # ---------------------------------------------------------------------------
  echo ""
  echo "==> Creating argocd-repo-server-mtls Secret with generated certs..."

  CERTS_DIR="${SCRIPT_DIR}/certs"

  kubectl create secret generic argocd-repo-server-mtls \
    --from-file=client-ca.crt="${CERTS_DIR}/ca.crt" \
    --from-file=client.crt="${CERTS_DIR}/client.crt" \
    --from-file=client.key="${CERTS_DIR}/client.key" \
    --from-file=server-ca.crt="${CERTS_DIR}/ca.crt" \
    -n "${ARGOCD_NS}" 2>/dev/null || \
  kubectl create secret generic argocd-repo-server-mtls \
    --from-file=client-ca.crt="${CERTS_DIR}/ca.crt" \
    --from-file=client.crt="${CERTS_DIR}/client.crt" \
    --from-file=client.key="${CERTS_DIR}/client.key" \
    --from-file=server-ca.crt="${CERTS_DIR}/ca.crt" \
    -n "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f -

  echo "    Secret created in ${ARGOCD_NS} namespace"
else
  echo ""
  echo "==> mTLS is DISABLED (ENABLE_MTLS=false)"
fi

# ---------------------------------------------------------------------------
# Verify mTLS volume configuration (if enabled)
# ---------------------------------------------------------------------------
if [[ "${ENABLE_MTLS}" == "true" ]]; then
  echo ""
  echo "==> Verifying mTLS volumes are configured in manifests..."

  REPO_SERVER_VOLUME=$(kubectl -n "${ARGOCD_NS}" get deployment argocd-repo-server \
    -o jsonpath='{.spec.template.spec.volumes[?(@.name=="argocd-repo-server-mtls")]}' 2>/dev/null)

  if [[ -n "${REPO_SERVER_VOLUME}" ]]; then
    echo "    ✓ mTLS volume is configured in repo-server deployment"
  else
    if [[ "${INSTALL_MODE}" == "release" ]]; then
      echo "    ⚠️  mTLS volume not found in upstream ${ARGOCD_VERSION} manifests"
      echo "       The native mTLS support may not be available in this version."
    else
      echo "    ❌ ERROR: mTLS volume not found in local manifests!"
      exit 1
    fi
  fi
fi

echo ""
if [[ "${ENABLE_MTLS}" == "true" ]]; then
  echo "==> Restarting Argo CD components to enable mTLS..."
else
  echo "==> Restarting Argo CD components..."
fi

kubectl rollout restart deployment/argocd-server -n "${ARGOCD_NS}" 2>/dev/null || true
kubectl rollout restart deployment/argocd-repo-server -n "${ARGOCD_NS}" 2>/dev/null || true
kubectl rollout restart deployment/argocd-applicationset-controller -n "${ARGOCD_NS}" 2>/dev/null || true
kubectl rollout restart deployment/argocd-notifications-controller -n "${ARGOCD_NS}" 2>/dev/null || true
kubectl rollout restart statefulset/argocd-application-controller -n "${ARGOCD_NS}" 2>/dev/null || true

# Wait for components to be ready
echo ""
echo "==> Waiting for components to stabilize (up to 3 min)..."
kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NS}" --timeout=180s 2>/dev/null || true
kubectl rollout status deployment/argocd-repo-server \
  -n "${ARGOCD_NS}" --timeout=180s 2>/dev/null || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo " Setup complete!"
echo " Cluster      : k3d-${CLUSTER_NAME}"
echo " Argo CD      : ${ARGOCD_NS} namespace"
echo " mTLS Status  : $([ "${ENABLE_MTLS}" == "true" ] && echo "ENABLED ✓" || echo "DISABLED")"
if [[ "${ENABLE_MTLS}" == "true" ]]; then
  echo " mTLS Certs   : ${CERTS_DIR}"
fi
echo ""
echo " Access Argo CD:"
echo "   kubectl port-forward -n argocd svc/argocd-server 8080:443"
echo "   → https://localhost:8080 (accept self-signed cert warning)"
echo ""
echo "   Get admin password:"
echo "   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
echo " Next steps:"
echo "   ./verify.sh         — verify mTLS is working correctly"
if [[ "${ENABLE_MTLS}" == "true" ]]; then
  echo "   ./setup-per-component-option-a.sh — test per-component certs (Option A)"
  echo "   ./setup-per-component-option-b.sh — test per-component certs (Option B)"
fi
echo "   ./teardown.sh       — destroy the cluster when done"
echo "========================================"
