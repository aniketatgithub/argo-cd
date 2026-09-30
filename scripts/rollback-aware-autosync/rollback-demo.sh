#!/usr/bin/env bash
# Git fixture for manually testing rollback-aware auto-sync (#9570).
#
#   ./rollback-demo.sh init   # fresh bare repo, one commit (v1)
#   ./rollback-demo.sh v2     # push the good revision
#   ./rollback-demo.sh v3     # push the bad revision (image that cannot be pulled)
#   ./rollback-demo.sh v3b    # push a *second*, different bad revision
#   ./rollback-demo.sh fix    # push the fix by reverting (same manifests as the good revision)
#   ./rollback-demo.sh fixfwd # push a fix forward (manifests differ, so a sync really runs)
#   ./rollback-demo.sh log    # show the history
#   ./rollback-demo.sh url    # print the repo URL to give to "argocd app create"
#
# The repo server runs on the host under "make start-local", so a file:// URL works.
# Kept out of /tmp because macOS prunes that: override with BARE= / WORK= if you like.
set -euo pipefail

BARE=${BARE:-$HOME/.argocd-dev/rollback-demo.git}
WORK=${WORK:-$HOME/.argocd-dev/rollback-demo}

write_deploy() { # replicas image
  mkdir -p "$WORK/manifests"
  cat > "$WORK/manifests/deployment.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rollback-demo
spec:
  replicas: $1
  selector:
    matchLabels:
      app: rollback-demo
  template:
    metadata:
      labels:
        app: rollback-demo
    spec:
      containers:
        - name: web
          image: $2
          ports:
            - containerPort: 80
YAML
}

commit_push() { # message
  cd "$WORK"
  git add -A
  if git diff --cached --quiet; then
    echo "already at \"$1\" ($(git rev-parse --short HEAD)), nothing to push"
    return 0
  fi
  git commit -q -m "$1"
  git push -q origin main
  echo "pushed $(git rev-parse --short HEAD)  $1"
}

case "${1:-}" in
  init)
    rm -rf "$BARE" "$WORK"
    mkdir -p "$(dirname "$BARE")"
    git init --bare -q -b main "$BARE"
    git clone -q "$BARE" "$WORK" 2>/dev/null
    cd "$WORK"
    git config user.email dev@example.com
    git config user.name "Local Dev"
    git symbolic-ref HEAD refs/heads/main
    write_deploy 1 "nginx:1.27-alpine"
    commit_push "v1: one replica"
    echo "repo URL: file://$BARE"
    ;;
  v2)  write_deploy 2 "nginx:1.27-alpine";      commit_push "v2: two replicas (the good one)" ;;
  v3)  write_deploy 2 "nginx:no-such-tag-9570"; commit_push "v3: broken image (the bad one)" ;;
  # A second bad revision that differs from "v3", so pushing it after a rollback really does move the
  # desired revision. Re-running "v3" would be a no-op and would leave auto-sync paused.
  v3b) write_deploy 3 "nginx:no-such-tag-9570b"; commit_push "v3b: another broken image" ;;
  fix) write_deploy 2 "nginx:1.27-alpine";      commit_push "v4: revert to a working image" ;;
  # Same intent as "fix", but the manifests differ from the rolled-back-to revision, so the
  # repair actually runs a sync instead of landing on Synced with nothing to apply.
  fixfwd) write_deploy 3 "nginx:1.27-alpine";   commit_push "v5: fix forward, three replicas" ;;
  log) git -C "$WORK" --no-pager log --oneline ;;
  url) echo "file://$BARE" ;;
  *)   sed -n '2,11p' "$0"; exit 1 ;;
esac
