#!/usr/bin/env bash
set -euo pipefail

# Tests Option B — One Secret per component — as described in
# docs/operator-manual/mtls.md § "Option B — One Secret per component".
#
# Assumes:
#   1. scripts/mtls/setup.sh has already been executed (cluster running, local image imported,
#      base mTLS working with the shared argocd-repo-server-mtls secret).
#   2. scripts/mtls/gencerts-per-component.sh has been run to produce per-component cert files.
#
# What this script does:
#   - Creates one Secret per client component:
#       argocd-repo-server-mtls-server
#       argocd-repo-server-mtls-controller
#       argocd-repo-server-mtls-appsetcontroller
#   - For each client deployment:
#       a) Removes the auto-mounted argocd-repo-server-mtls volume (to avoid mount path conflict).
#       b) Adds a new volume pointing to the component-specific Secret.
#       c) Adds a volumeMount at /app/config/reposerver/mtls (same canonical path).
#   - The repo-server and its --client-ca-path flag are left unchanged.
#   - Waits for all rollouts to complete.
#   - Runs verify.sh to confirm mTLS is still working end-to-end.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"
CLUSTER_NAME="argocd-mtls"
NAMESPACE="argocd"
MTLS_MOUNT="/app/config/reposerver/mtls"

echo "==> Checking prerequisites..."
for cmd in kubectl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ '$cmd' is required"; exit 1; }
done

for f in \
  "${CERT_DIR}/ca.crt" \
  "${CERT_DIR}/server-client.crt"     "${CERT_DIR}/server-client.key" \
  "${CERT_DIR}/controller-client.crt" "${CERT_DIR}/controller-client.key" \
  "${CERT_DIR}/appset-client.crt"     "${CERT_DIR}/appset-client.key"; do
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
# 1. Create per-component Secrets
# ---------------------------------------------------------------------------
echo "==> Creating per-component Secrets (Option B)..."

for secret in argocd-repo-server-mtls-server argocd-repo-server-mtls-controller argocd-repo-server-mtls-appsetcontroller; do
  kubectl -n "${NAMESPACE}" delete secret "${secret}" 2>/dev/null || true
done

kubectl -n "${NAMESPACE}" create secret generic argocd-repo-server-mtls-server \
  --from-file=client.crt="${CERT_DIR}/server-client.crt" \
  --from-file=client.key="${CERT_DIR}/server-client.key" \
  --from-file=client-ca.crt="${CERT_DIR}/ca.crt"

kubectl -n "${NAMESPACE}" create secret generic argocd-repo-server-mtls-controller \
  --from-file=client.crt="${CERT_DIR}/controller-client.crt" \
  --from-file=client.key="${CERT_DIR}/controller-client.key" \
  --from-file=client-ca.crt="${CERT_DIR}/ca.crt"

kubectl -n "${NAMESPACE}" create secret generic argocd-repo-server-mtls-appsetcontroller \
  --from-file=client.crt="${CERT_DIR}/appset-client.crt" \
  --from-file=client.key="${CERT_DIR}/appset-client.key" \
  --from-file=client-ca.crt="${CERT_DIR}/ca.crt"

# ---------------------------------------------------------------------------
# 2. Helper: find the index of the auto-mounted argocd-repo-server-mtls volume
# ---------------------------------------------------------------------------
volume_index() {
  local kind="$1" name="$2"
  kubectl -n "${NAMESPACE}" get "${kind}" "${name}" \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' \
    | grep -n "^argocd-repo-server-mtls$" \
    | head -1 \
    | cut -d: -f1 \
    | awk '{print $1 - 1}'
}

# Helper: find the index of the volumeMount for the auto-mounted volume
volumemount_index() {
  local kind="$1" name="$2"
  kubectl -n "${NAMESPACE}" get "${kind}" "${name}" \
    -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}{"\n"}{end}' \
    | grep -n "^argocd-repo-server-mtls$" \
    | head -1 \
    | cut -d: -f1 \
    | awk '{print $1 - 1}'
}

# ---------------------------------------------------------------------------
# 3. Patch each client deployment:
#    - Remove the auto-mounted argocd-repo-server-mtls volume + volumeMount
#    - Add the component-specific volume + volumeMount at the same mount path
# ---------------------------------------------------------------------------
patch_component() {
  local kind="$1" name="$2" secret_name="$3" vol_name="$4"
  local vidx midx

  vidx=$(volume_index "${kind}" "${name}")
  midx=$(volumemount_index "${kind}" "${name}")

  echo "   - patching ${kind}/${name}: removing auto-mount (vol[${vidx}], mount[${midx}]), adding ${secret_name}"

  # Remove the auto-mounted volume and its volumeMount (remove higher index first to avoid index shift)
  # Determine which index is higher to remove it first
  if [[ "${vidx}" -gt "${midx}" ]]; then
    kubectl -n "${NAMESPACE}" patch "${kind}" "${name}" --type='json' -p="[
      {\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/${vidx}\"},
      {\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/${midx}\"}
    ]"
  else
    kubectl -n "${NAMESPACE}" patch "${kind}" "${name}" --type='json' -p="[
      {\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/${midx}\"},
      {\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/${vidx}\"}
    ]"
  fi

  # Add the component-specific volume and volumeMount
  kubectl -n "${NAMESPACE}" patch "${kind}" "${name}" --type='json' -p="[
    {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{
      \"name\":\"${vol_name}\",
      \"secret\":{\"secretName\":\"${secret_name}\"}
    }},
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{
      \"name\":\"${vol_name}\",
      \"mountPath\":\"${MTLS_MOUNT}\",
      \"readOnly\":true
    }}
  ]"
}

echo "==> Patching client deployments to use per-component Secrets..."
patch_component deploy      argocd-server                    argocd-repo-server-mtls-server          argocd-repo-server-mtls-server
patch_component statefulset argocd-application-controller    argocd-repo-server-mtls-controller      argocd-repo-server-mtls-controller
patch_component deploy      argocd-applicationset-controller argocd-repo-server-mtls-appsetcontroller argocd-repo-server-mtls-appsetcontroller

# ---------------------------------------------------------------------------
# 4. Wait for rollouts
# ---------------------------------------------------------------------------
echo "==> Waiting for rollouts..."
kubectl rollout status deploy/argocd-server                      -n "${NAMESPACE}" --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deploy/argocd-applicationset-controller   -n "${NAMESPACE}" --timeout=300s

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
echo "==> Running verify.sh to confirm mTLS is still working..."
bash "${SCRIPT_DIR}/verify.sh"

echo ""
echo "✅ Option B (one Secret per component) test complete."
echo "   Each component mounts its own Secret at ${MTLS_MOUNT}."
echo "   The repo-server accepts all of them because they are all signed by the same client CA."
