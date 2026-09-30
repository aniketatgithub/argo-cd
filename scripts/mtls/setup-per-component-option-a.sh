#!/usr/bin/env bash
set -euo pipefail

# Tests Option A — Multiple keys in one Secret — as described in
# docs/operator-manual/mtls.md § "Option A — Multiple keys in one Secret".
#
# Assumes:
#   1. scripts/mtls/setup.sh has already been executed (cluster running, local image imported,
#      base mTLS working with the shared argocd-repo-server-mtls secret).
#   2. scripts/mtls/gencerts-per-component.sh has been run to produce per-component cert files.
#
# What this script does:
#   - Recreates argocd-repo-server-mtls with per-component keys
#     (server-client.crt/key, controller-client.crt/key, appset-client.crt/key)
#     alongside the existing client-ca.crt.
#   - Patches each client deployment's volume items projection so that each component
#     sees its own cert at the canonical path /app/config/reposerver/mtls/client.crt|key.
#   - The repo-server and its --client-ca-path flag are left unchanged.
#   - Waits for all rollouts to complete.
#   - Runs verify.sh to confirm mTLS is still working end-to-end.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"
CLUSTER_NAME="argocd-mtls"
NAMESPACE="argocd"

echo "==> Checking prerequisites..."
for cmd in kubectl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ '$cmd' is required"; exit 1; }
done

for f in \
  "${CERT_DIR}/ca.crt" \
  "${CERT_DIR}/server-client.crt"        "${CERT_DIR}/server-client.key" \
  "${CERT_DIR}/controller-client.crt"    "${CERT_DIR}/controller-client.key" \
  "${CERT_DIR}/appset-client.crt"        "${CERT_DIR}/appset-client.key" \
  "${CERT_DIR}/notifications-client.crt" "${CERT_DIR}/notifications-client.key"; do
  [[ -f "$f" ]] || { echo "❌ Missing cert file: $f — run gencerts-per-component.sh first."; exit 1; }
done

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true

# Verify repo-server has the argocd-repo-server-mtls volume (from setup.sh)
echo "==> Verifying repo-server has mTLS volume..."
REPO_SERVER_VOLUME=$(kubectl -n "${NAMESPACE}" get deployment argocd-repo-server \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="argocd-repo-server-mtls")]}' 2>/dev/null)

if [[ -z "${REPO_SERVER_VOLUME}" ]]; then
  echo "❌ ERROR: argocd-repo-server does not have the argocd-repo-server-mtls volume!"
  echo "   Run setup.sh first to mount the mTLS volume."
  exit 1
fi
echo "    ✅ Repo-server has argocd-repo-server-mtls volume"

# ---------------------------------------------------------------------------
# 1. Recreate argocd-repo-server-mtls with all per-component keys
# ---------------------------------------------------------------------------
echo "==> Recreating argocd-repo-server-mtls with per-component keys (Option A)..."
kubectl -n "${NAMESPACE}" delete secret argocd-repo-server-mtls 2>/dev/null || true
kubectl -n "${NAMESPACE}" create secret generic argocd-repo-server-mtls \
  --from-file=client-ca.crt="${CERT_DIR}/ca.crt" \
  --from-file=server-client.crt="${CERT_DIR}/server-client.crt" \
  --from-file=server-client.key="${CERT_DIR}/server-client.key" \
  --from-file=controller-client.crt="${CERT_DIR}/controller-client.crt" \
  --from-file=controller-client.key="${CERT_DIR}/controller-client.key" \
  --from-file=appset-client.crt="${CERT_DIR}/appset-client.crt" \
  --from-file=appset-client.key="${CERT_DIR}/appset-client.key" \
  --from-file=notifications-client.crt="${CERT_DIR}/notifications-client.crt" \
  --from-file=notifications-client.key="${CERT_DIR}/notifications-client.key"

# ---------------------------------------------------------------------------
# 2. Patch each client deployment's volume items projection
#    so the component-specific cert is exposed at the canonical path.
#    The auto-mounted volume name is "argocd-repo-server-mtls"; we replace
#    its items list using a strategic-merge-patch on the pod template.
# ---------------------------------------------------------------------------

# Helper: find the index of the argocd-repo-server-mtls volume in a workload
volume_index() {
  local kind="$1" name="$2"
  local idx
  idx=$(kubectl -n "${NAMESPACE}" get "${kind}" "${name}" \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' \
    | grep -n "^argocd-repo-server-mtls$" \
    | head -1 \
    | cut -d: -f1)

  if [[ -z "${idx}" ]]; then
    echo "ERROR: Could not find argocd-repo-server-mtls volume in ${kind}/${name}" >&2
    return 1
  fi

  # Convert to 0-indexed
  echo $((idx - 1))
}

patch_volume_items() {
  local kind="$1" name="$2" cert_key="$3" key_key="$4"
  local idx

  idx=$(volume_index "${kind}" "${name}") || {
    echo "ERROR: Failed to get volume index for ${kind}/${name}" >&2
    return 1
  }

  echo "   - patching ${kind}/${name} volume[${idx}] items (cert=${cert_key}, key=${key_key})"
  kubectl -n "${NAMESPACE}" patch "${kind}" "${name}" --type='json' -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/${idx}/secret/items\",\"value\":[
      {\"key\":\"${cert_key}\",\"path\":\"client.crt\"},
      {\"key\":\"${key_key}\",\"path\":\"client.key\"},
      {\"key\":\"client-ca.crt\",\"path\":\"client-ca.crt\"}
    ]}
  ]" || {
    echo "ERROR: Failed to patch ${kind}/${name}" >&2
    return 1
  }
}

echo "==> Patching volume items projections per component..."
patch_volume_items deploy      argocd-server                  server-client.crt        server-client.key
patch_volume_items statefulset argocd-application-controller  controller-client.crt    controller-client.key
patch_volume_items deploy      argocd-applicationset-controller appset-client.crt      appset-client.key

# ---------------------------------------------------------------------------
# 3. Wait for rollouts
# ---------------------------------------------------------------------------
echo "==> Waiting for rollouts..."
kubectl rollout status deploy/argocd-server                    -n "${NAMESPACE}" --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deploy/argocd-applicationset-controller -n "${NAMESPACE}" --timeout=300s

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------
echo "==> Running verify.sh to confirm mTLS is still working..."
bash "${SCRIPT_DIR}/verify.sh"

echo ""
echo "✅ Option A (multiple keys in one Secret) test complete."
echo "   Each component now presents its own cert (CN=argocd-server, CN=argocd-application-controller, etc.)"
echo "   The repo-server accepts all of them because they are all signed by the same client CA."
