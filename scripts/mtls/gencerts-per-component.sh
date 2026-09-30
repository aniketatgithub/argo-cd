#!/usr/bin/env bash
set -euo pipefail

# Generates per-component client certificates for testing Option A and Option B
# of per-component mTLS client certificates described in docs/operator-manual/mtls.md.
#
# Assumes gencerts.sh has already been run (reuses the existing CA and server cert).
#
# New files written to ./scripts/mtls/certs:
#   server-client.crt / server-client.key         : cert for argocd-server
#   controller-client.crt / controller-client.key : cert for argocd-application-controller
#   appset-client.crt / appset-client.key         : cert for argocd-applicationset-controller
#   notifications-client.crt / notifications-client.key : cert for argocd-notifications-controller

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/certs"

if [[ ! -f "${OUT_DIR}/ca.crt" || ! -f "${OUT_DIR}/ca.key" ]]; then
  echo "❌ CA not found under ${OUT_DIR}. Run scripts/mtls/gencerts.sh first."
  exit 1
fi

CLIENT_EXT="${OUT_DIR}/client.ext"
cat >"${CLIENT_EXT}" <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

gen_client_cert() {
  local name="$1"   # e.g. "server-client"
  local cn="$2"     # e.g. "argocd-server"

  echo "==> Generating client cert for ${cn} (${name})..."
  openssl genrsa -out "${OUT_DIR}/${name}.key" 4096 1>/dev/null 2>&1

  cat >"${OUT_DIR}/${name}.csr.cnf" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn

[ dn ]
CN = ${cn}
O  = ArgoCD
OU = Client
EOF

  openssl req -new \
    -key "${OUT_DIR}/${name}.key" \
    -out "${OUT_DIR}/${name}.csr" \
    -config "${OUT_DIR}/${name}.csr.cnf" 1>/dev/null 2>&1

  openssl x509 -req \
    -in "${OUT_DIR}/${name}.csr" \
    -CA "${OUT_DIR}/ca.crt" \
    -CAkey "${OUT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${OUT_DIR}/${name}.crt" \
    -days 3650 -sha256 \
    -extfile "${CLIENT_EXT}" 1>/dev/null 2>&1

  echo "    -> ${OUT_DIR}/${name}.crt"
}

gen_client_cert "server-client"        "argocd-server"
gen_client_cert "controller-client"    "argocd-application-controller"
gen_client_cert "appset-client"        "argocd-applicationset-controller"
gen_client_cert "notifications-client" "argocd-notifications-controller"

echo "==> Done. Per-component cert files:"
ls -1 "${OUT_DIR}"/*-client.{crt,key} 2>/dev/null | sed 's/^/    /'
