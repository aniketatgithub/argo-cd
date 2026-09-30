# Argo CD mTLS Testing & Verification

This directory contains scripts to set up, configure, and verify Argo CD's native mTLS (mutual TLS) support introduced in v3.5.0.

## Quick Start

```bash
# 1. Create a k3d cluster with Argo CD and mTLS enabled (default)
./setup.sh

# 2. Verify mTLS is working
./verify.sh

# 3. Test per-component certificate options (optional)
./setup-per-component-option-a.sh  # or
./setup-per-component-option-b.sh

# 4. Clean up
./teardown.sh
```

---

## Accessing Argo CD

After `setup.sh` completes, Argo CD is deployed but **not exposed to localhost by default**. Use port forwarding to access it via browser.

### Via Browser (Recommended for Testing)

```bash
# Terminal 1: Start port forwarding
kubectl port-forward -n argocd svc/argocd-server 8080:443 --address=127.0.0.1

# Terminal 2: Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Then open: **https://localhost:8080**
- Username: `admin`
- Password: (output from command above)
- Accept the self-signed certificate warning

### Via Argo CD CLI

```bash
# Get admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Login
argocd login localhost:8080 \
  --username admin \
  --password "$ARGOCD_PASSWORD" \
  --insecure

# Now use argocd commands
argocd app list
```

### Verify Components Are Running

```bash
# Check all pods are running
kubectl -n argocd get pods

# Check services
kubectl -n argocd get svc

# Check repo-server health
kubectl -n argocd logs deploy/argocd-repo-server | tail -20
```

---

## Scripts Overview

### Core Setup & Verification

#### `setup.sh`
Provisions a k3d cluster with Argo CD and optional mTLS configuration.

**Capabilities:**
- Creates a k3d cluster named `argocd-mtls`
- Installs Argo CD from a local codebase or released version
- Generates mTLS certificates (when enabled)
- Creates the `argocd-repo-server-mtls` Secret
- Configures repo-server to enforce client certificate verification

**Usage:**
```bash
# Default: local image build, mTLS enabled
./setup.sh

# Use specific released version (RC1 or later)
ARGOCD_VERSION=v3.5.0-rc1 ./setup.sh

# Use pre-built local image
ARGOCD_IMAGE=argocd:dev ./setup.sh

# Disable mTLS (for baseline testing)
ENABLE_MTLS=false ./setup.sh

# Combine options
ARGOCD_IMAGE=argocd:dev ENABLE_MTLS=true ./setup.sh
```

**Environment Variables:**
| Variable | Default | Purpose |
|----------|---------|---------|
| `ARGOCD_VERSION` | `v3.5.0-rc1` | Argo CD version to install (used if `ARGOCD_IMAGE` not set) |
| `ARGOCD_IMAGE` | *(unset)* | Local Docker image (takes precedence over `ARGOCD_VERSION`) |
| `CLUSTER_NAME` | `argocd-mtls` | k3d cluster name |
| `ENABLE_MTLS` | `true` | Enable mTLS setup (true/false) |

**What it does:**
1. ✅ Checks for required tools (docker, k3d, kubectl, openssl)
2. ✅ Builds local image if `ARGOCD_IMAGE` is set and doesn't exist
3. ✅ Creates k3d cluster
4. ✅ Imports local image into cluster
5. ✅ Applies Argo CD manifests (local for custom images, upstream for releases)
6. ✅ (If mTLS enabled) Generates CA, client, and server certificates
7. ✅ (If mTLS enabled) Creates `argocd-repo-server-mtls` Secret
8. ✅ Waits for rollouts and pod stabilization
9. ✅ Verifies volumes are properly configured

**Notes:**
- When using `ARGOCD_IMAGE`, the script uses **local manifests** from the codebase (includes mTLS volumes)
- When using `ARGOCD_VERSION`, the script downloads upstream manifests
- mTLS is opt-in via `ENABLE_MTLS` flag (defaults to true)
- Certificates are generated in `./certs/` directory

---

#### `verify.sh`
Verifies that mTLS is properly configured and enforced.

**What it checks:**
1. **Log verification:** Confirms repo-server generated an ephemeral health-check certificate
2. **No-cert test:** Connects WITHOUT a client certificate — should fail with "certificate required" error
3. **With-cert test:** Connects WITH valid client certificate — should succeed

**Usage:**
```bash
./verify.sh
```

**Output:**
```
==> Waiting for repo-server to be Running...
    ✅ Found ephemeral health-check cert line: ...
==> No-cert probe confirmed mTLS is enforced
==> With-cert probe succeeded as expected

🎉 mTLS verification passed — all checks successful.
```

**If mTLS is NOT enforced:**
- No-cert test will succeed (should fail) ❌
- Script exits with error code 1
- Suggests checking repo-server logs

---

### Certificate Generation

#### `gencerts.sh`
Generates a self-signed CA and client/server certificates for shared mTLS configuration.

**Generated files** (in `./certs/`):
- `ca.crt` — Root CA certificate (used by repo-server to verify client certs)
- `client.crt` / `client.key` — Client certificate (used by all components connecting to repo-server)
- `server.crt` / `server.key` — Server certificate (used by repo-server)

**When called:** Automatically invoked by `setup.sh` when `ENABLE_MTLS=true`

---

#### `gencerts-per-component.sh`
Generates per-component certificates for use with Option A or Option B configurations.

**Generated files** (in `./certs/`):
- `ca.crt` — Shared root CA
- `server-client.crt/key` — For argocd-server
- `controller-client.crt/key` — For argocd-application-controller
- `appset-client.crt/key` — For argocd-applicationset-controller
- `notifications-client.crt/key` — For argocd-notifications-controller

**Usage:**
```bash
./gencerts-per-component.sh
```

**When to use:** Before running Option A or Option B setup scripts

---

### Per-Component Configuration Options

#### `setup-per-component-option-a.sh`
Configures **Option A**: Multiple keys in one Secret

**How it works:**
1. Recreates `argocd-repo-server-mtls` Secret with all per-component keys:
   - `server-client.crt/key`
   - `controller-client.crt/key`
   - `appset-client.crt/key`
   - `notifications-client.crt/key`
   - `client-ca.crt` (shared)
2. Patches each client deployment's volume items projection
3. Each component sees its own cert at canonical path `/app/config/reposerver/mtls/client.crt`

**Usage:**
```bash
# Generate per-component certs first
./gencerts-per-component.sh

# Apply Option A configuration
./setup-per-component-option-a.sh

# Verify it still works
./verify.sh
```

**Architecture:**
```
Secret: argocd-repo-server-mtls
  ├── server-client.crt
  ├── server-client.key
  ├── controller-client.crt
  ├── controller-client.key
  ├── appset-client.crt
  ├── appset-client.key
  ├── notifications-client.crt
  ├── notifications-client.key
  └── client-ca.crt (shared)

Deployments (with volume items projection):
  ├── argocd-server → sees server-client.crt/key
  ├── argocd-application-controller → sees controller-client.crt/key
  ├── argocd-applicationset-controller → sees appset-client.crt/key
  └── argocd-notifications-controller → sees notifications-client.crt/key
```

**Pros:**
- Single Secret to manage (smaller footprint)
- Volume items projection is pure Kubernetes
- Clean when using ConfigMap generators or Kustomize

**Cons:**
- More complex volume items configuration
- All keys in one Secret increases blast radius if compromised

---

#### `setup-per-component-option-b.sh`
Configures **Option B**: One Secret per component

**How it works:**
1. Creates separate Secrets for each component:
   - `argocd-repo-server-mtls-server`
   - `argocd-repo-server-mtls-controller`
   - `argocd-repo-server-mtls-appsetcontroller`
2. Removes auto-mounted `argocd-repo-server-mtls` volume from clients
3. Adds component-specific volume pointing to component's Secret
4. Each component mounts its Secret at `/app/config/reposerver/mtls`

**Usage:**
```bash
# Generate per-component certs first
./gencerts-per-component.sh

# Apply Option B configuration
./setup-per-component-option-b.sh

# Verify it still works
./verify.sh
```

**Architecture:**
```
Secrets (one per component):
  ├── argocd-repo-server-mtls-server
  │   ├── client.crt (server-client.crt)
  │   ├── client.key (server-client.key)
  │   └── client-ca.crt
  ├── argocd-repo-server-mtls-controller
  │   ├── client.crt (controller-client.crt)
  │   ├── client.key (controller-client.key)
  │   └── client-ca.crt
  └── argocd-repo-server-mtls-appsetcontroller
      ├── client.crt (appset-client.crt)
      ├── client.key (appset-client.key)
      └── client-ca.crt

Deployments (each with own volume):
  ├── argocd-server → volume: argocd-repo-server-mtls-server
  ├── argocd-application-controller → volume: argocd-repo-server-mtls-controller
  └── argocd-applicationset-controller → volume: argocd-repo-server-mtls-appsetcontroller
```

**Pros:**
- True isolation: each component's secret is separate
- Easier RBAC: can grant per-component access
- Simpler troubleshooting: clear 1:1 mapping
- Credential rotation: update one component's secret independently

**Cons:**
- More Secrets to manage (3+ instead of 1)
- More volume mounts in deployment specs

---

### Cleanup

#### `teardown.sh`
Destroys the k3d cluster and removes generated certificates.

**Usage:**
```bash
./teardown.sh
```

**What it does:**
- Deletes k3d cluster (`k3d-argocd-mtls`)
- Removes generated certificates in `./certs/` directory
- Removes kubeconfig context

---

## Configuration Decisions

### Shared vs Per-Component Certificates

| Aspect | Shared (Default) | Option A (Multi-key) | Option B (Multi-secret) |
|--------|------------------|----------------------|------------------------|
| **Secrets** | 1 (`argocd-repo-server-mtls`) | 1 (`argocd-repo-server-mtls`) | 3+ (one per component) |
| **Setup complexity** | Simplest | Medium | Medium |
| **Credential rotation** | All at once | All at once | Per-component |
| **RBAC isolation** | Single RBAC rule | Single RBAC rule | Per-component RBAC |
| **Blast radius** | High | High | Low |
| **Use case** | Quick testing, dev/staging | When isolation matters | Production, multi-tenant |

### When to use each option:

**Shared (Default):**
- Development & testing
- Single-tenant environments
- Quick verification
- CI/CD pipelines

**Option A (Multiple keys in one Secret):**
- Need per-component certs but want single Secret
- Kubernetes-native volume items projection
- Easier Kustomize/Helm integration
- Moderate security posture

**Option B (One Secret per component):**
- Production deployments
- Multi-tenant environments
- Granular RBAC per component
- Independent credential rotation needed
- High security requirements

---

## Troubleshooting

### mTLS not enforced (verify.sh fails)

**Problem:** Connection succeeds without client certificate

**Checks:**
```bash
# 1. Verify Secret exists
kubectl -n argocd get secret argocd-repo-server-mtls

# 2. Check volume is mounted in pod
kubectl -n argocd exec -it deploy/argocd-repo-server -- ls -la /app/config/reposerver/mtls/

# 3. Check repo-server logs
kubectl -n argocd logs deploy/argocd-repo-server | grep -i "ephemeral\|mtls\|certificate"

# 4. Verify deployment has volumeMount
kubectl -n argocd get deploy argocd-repo-server -o yaml | grep -A 10 volumeMounts
```

**Solutions:**
- Ensure Secret exists: `kubectl -n argocd get secret argocd-repo-server-mtls`
- Restart pods: `kubectl -n argocd rollout restart deploy/argocd-repo-server`
- Check manifests have volume configured
- Verify cert files in Secret: `kubectl -n argocd get secret argocd-repo-server-mtls -o jsonpath='{.data}' | jq`

### Certificate validation errors

**Problem:** "certificate required" or "bad certificate" errors

**Checks:**
```bash
# Verify cert files
openssl x509 -in ./certs/client.crt -text -noout
openssl x509 -in ./certs/server.crt -text -noout

# Check CA is in Secret
kubectl -n argocd get secret argocd-repo-server-mtls -o jsonpath='{.data.client-ca\.crt}' | base64 -d | openssl x509 -text -noout

# Verify cert is signed by CA
openssl verify -CAfile ./certs/ca.crt ./certs/client.crt
```

**Solutions:**
- Regenerate certificates: `./gencerts.sh`
- Recreate Secret: `kubectl delete secret argocd-repo-server-mtls -n argocd && ./setup.sh`

### Pod not picking up new configuration

**Problem:** Deployment changed but pod still has old spec

**Solution:**
```bash
# Force pod restart
kubectl -n argocd rollout restart deploy/argocd-repo-server
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout restart deploy/argocd-applicationset-controller
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

---

## How mTLS Works in Argo CD

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Argo CD Components                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  argocd-server ──┐                                          │
│  argocd-application-controller ──┼──→ argocd-repo-server   │
│  argocd-applicationset-controller ┘  (gRPC on :8081)       │
│  argocd-notifications-controller                            │
│                                                             │
│ All components present client cert from Secret             │
│ repo-server verifies client cert against CA                │
│ repo-server generates ephemeral health-check cert          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### TLS Handshake Flow

```
1. Client (e.g., argocd-server) connects to repo-server:8081
2. repo-server presents server certificate
3. Client verifies server certificate (basic TLS)
4. repo-server requests client certificate
5. Client presents client certificate from Secret
6. repo-server verifies client certificate against CA
7. Connection established (mutual authentication)
```

### Certificate Lifecycle

- **Generation:** `gencerts.sh` creates self-signed certificates
- **Storage:** Certificates stored in Kubernetes Secret `argocd-repo-server-mtls`
- **Distribution:** Secret mounted as volume in all components
- **Ephemeral health-check cert:** repo-server generates at startup for liveness probe
- **Rotation:** Currently manual (regenerate with `gencerts.sh` and recreate Secret)

---

## Advanced Usage

### Using existing certificates

```bash
# Don't run gencerts.sh, instead:
kubectl create secret generic argocd-repo-server-mtls \
  --from-file=client-ca.crt=/path/to/ca.crt \
  --from-file=client.crt=/path/to/client.crt \
  --from-file=client.key=/path/to/client.key \
  --from-file=server-ca.crt=/path/to/ca.crt \
  -n argocd

kubectl rollout restart deploy/argocd-server -n argocd
kubectl rollout restart deploy/argocd-repo-server -n argocd
# ... restart other components
```

### Integrating with cert-manager

```bash
# Create a Certificate resource (cert-manager)
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-repo-server-mtls
  namespace: argocd
spec:
  secretName: argocd-repo-server-mtls
  # ... configure issuer, duration, etc.
```

### Disabling mTLS temporarily

```bash
# Remove the Secret (optional volumes won't mount)
kubectl delete secret argocd-repo-server-mtls -n argocd

# Or set env var in repo-server (if supported)
kubectl set env deploy/argocd-repo-server -n argocd ARGOCD_REPO_SERVER_STRICT_TLS=false
```
