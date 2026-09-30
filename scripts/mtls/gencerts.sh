#!/usr/bin/env bash
set -euo pipefail

# This script generates a minimal PKI to enable and verify repo-server mTLS locally.
# Files are written to ./scripts/mtls/certs
# - ca.crt / ca.key                    : Client CA (also used to sign server for simplicity)
# - server.crt / server.key            : Server certificate for argocd-repo-server
# - client.crt / client.key            : Shared client certificate used by Argo CD clients

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/certs"
mkdir -p "${OUT_DIR}"

CN_REPOSERVER="reposerver"

echo "==> Generating Client CA..."
openssl genrsa -out "${OUT_DIR}/ca.key" 4096 1>/dev/null 2>&1
openssl req -x509 -new -nodes -key "${OUT_DIR}/ca.key" -sha256 -days 3650 \
  -subj "/CN=argocd-reposerver-client-ca" \
  -out "${OUT_DIR}/ca.crt" 1>/dev/null 2>&1
echo "    -> ${OUT_DIR}/ca.crt"

echo "==> Generating repo-server TLS key..."
openssl genrsa -out "${OUT_DIR}/server.key" 4096 1>/dev/null 2>&1

echo "==> Creating repo-server CSR..."
cat >"${OUT_DIR}/server.csr.cnf" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn

[ dn ]
CN = ${CN_REPOSERVER}
O  = ArgoCD
OU = RepoServer
EOF

cat >"${OUT_DIR}/server.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = reposerver
DNS.3 = argocd-repo-server
DNS.4 = argocd-repo-server.argocd
DNS.5 = argocd-repo-server.argocd.svc
DNS.6 = argocd-repo-server.argocd.svc.cluster.local
EOF

openssl req -new -key "${OUT_DIR}/server.key" -out "${OUT_DIR}/server.csr" -config "${OUT_DIR}/server.csr.cnf" 1>/dev/null 2>&1

echo "==> Signing repo-server cert with Client CA (for demo simplicity)..."
openssl x509 -req -in "${OUT_DIR}/server.csr" -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial \
  -out "${OUT_DIR}/server.crt" -days 3650 -sha256 -extfile "${OUT_DIR}/server.ext" 1>/dev/null 2>&1
echo "    -> ${OUT_DIR}/server.crt"

echo "==> Generating shared client certificate..."
openssl genrsa -out "${OUT_DIR}/client.key" 4096 1>/dev/null 2>&1
cat >"${OUT_DIR}/client.csr.cnf" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn

[ dn ]
CN = argocd-repo-client
O  = ArgoCD
OU = Client
EOF

cat >"${OUT_DIR}/client.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl req -new -key "${OUT_DIR}/client.key" -out "${OUT_DIR}/client.csr" -config "${OUT_DIR}/client.csr.cnf" 1>/dev/null 2>&1
openssl x509 -req -in "${OUT_DIR}/client.csr" -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial \
  -out "${OUT_DIR}/client.crt" -days 3650 -sha256 -extfile "${OUT_DIR}/client.ext" 1>/dev/null 2>&1
echo "    -> ${OUT_DIR}/client.crt"

echo "==> Done. Generated files:"
ls -1 "${OUT_DIR}" | sed 's/^/    /'
