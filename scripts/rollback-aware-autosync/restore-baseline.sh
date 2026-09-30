#!/usr/bin/env bash
# Restore the baseline for the #9570 manual tests: Synced, Healthy, no rolled-back record, no
# conditions, and rollback-aware inherited from argocd-cm with no per-app override.
#
#   ./restore-baseline.sh          clean reset: new fixture repo at v1, new application, one
#                                  history entry. This is the default: every case should start here
#   ./restore-baseline.sh --fast   push the good manifests forward and sync, keeping the
#                                  application and its history. Use it to un-break the app in the
#                                  middle of a case, where discarding the history would lose the
#                                  evidence the case is about
set -euo pipefail

NS=${NS:-argocd}
APP=${APP:-rollback-demo}
DEST_NS=${DEST_NS:-rollback-demo}
BARE=${BARE:-$HOME/.argocd-dev/rollback-demo.git}
WORK=${WORK:-$HOME/.argocd-dev/rollback-demo}
HERE=$(cd "$(dirname "$0")" && pwd)

# Prefer the branch build. A released argocd on PATH does not know --rollback-aware and, more
# quietly, cannot send spec.syncPolicy.automated.rollbackAware, so it would create an application
# that silently lacks the field. Override with ARGOCD= if your build lives somewhere else.
ARGOCD=${ARGOCD:-$(cd "$HERE/../.." && pwd)/dist/argocd}
if [ ! -x "$ARGOCD" ]; then
  echo "no branch build at $ARGOCD, falling back to the argocd on PATH"
  ARGOCD=argocd
fi

HARD=true
case "${1:-}" in
  --fast) HARD=false ;;
  --hard|"") ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac

echo "==> instance-wide default back on"
kubectl -n "$NS" patch cm argocd-cm --type merge \
  -p '{"data":{"application.rollbackAwareAutoSync":"true"}}' >/dev/null

if $HARD; then
  # Recreating the fixture repo invalidates every sha in status.history, so the application has to
  # go too: rolling back to a row whose commit no longer exists fails to resolve the revision.
  echo "==> deleting the application"
  if kubectl -n "$NS" get app "$APP" >/dev/null 2>&1; then
    "$ARGOCD" app delete "$APP" --cascade --yes >/dev/null
    if ! kubectl -n "$NS" wait --for=delete "app/$APP" --timeout=120s >/dev/null 2>&1; then
      echo "still present after 120s, probably a stuck finalizer. Clear it with"
      echo "  kubectl -n $NS patch app $APP --type merge -p '{\"metadata\":{\"finalizers\":null}}'"
      exit 1
    fi
    echo "    deleted"
  else
    echo "    already absent"
  fi

  echo "==> new fixture repo"
  "$HERE/rollback-demo.sh" init

  echo "==> creating the application"
  kubectl get ns "$DEST_NS" >/dev/null 2>&1 || kubectl create ns "$DEST_NS" >/dev/null
  "$ARGOCD" app create "$APP" \
    --repo "$("$HERE/rollback-demo.sh" url)" --path manifests --revision main \
    --dest-server https://kubernetes.default.svc --dest-namespace "$DEST_NS" \
    --sync-policy automated >/dev/null

else
  echo "==> dropping per-app overrides (the baseline has none)"
  for field in rollbackAware selfHeal; do
    if kubectl -n "$NS" patch app "$APP" --type json \
         -p "[{\"op\":\"remove\",\"path\":\"/spec/syncPolicy/automated/$field\"}]" >/dev/null 2>&1
    then
      echo "    removed $field"
    else
      echo "    $field already absent"
    fi
  done

  echo "==> pushing good manifests"
  "$HERE/rollback-demo.sh" fixfwd

  # "nothing to push" is expected when the repo already holds the good manifests, but it would
  # also be printed if an earlier run had failed after committing and before pushing, so check
  # that the remote agrees.
  if [ "$(git -C "$WORK" rev-parse HEAD)" != "$(git -C "$BARE" rev-parse main)" ]; then
    echo "    clone and remote disagree, pushing again"
    git -C "$WORK" push -q origin main
  fi
fi

echo "    main is at $(git -C "$BARE" rev-parse --short main)"

echo "==> refresh and wait"
"$ARGOCD" app get "$APP" --refresh >/dev/null
# Give auto-sync the first go. Syncing unconditionally would add a second history entry at the same
# revision, and a duplicate row is exactly what makes picking a rollback target in the UI go wrong.
if ! "$ARGOCD" app wait "$APP" --health --sync --timeout 60 >/dev/null 2>&1; then
  echo "    auto-sync did not converge, syncing explicitly"
  "$ARGOCD" app sync "$APP" --timeout 180 >/dev/null || true
  "$ARGOCD" app wait "$APP" --health --sync --timeout 180 >/dev/null || true
fi

echo "==> result"
RESULT=$(kubectl -n "$NS" get app "$APP" -o json | jq -c '{
  sync: .status.sync.status,
  desired: .status.sync.revision[0:7],
  health: .status.health.status,
  rolledBack: (.status.rolledBackRevision // ""),
  conds: [.status.conditions[]?.type],
  histLen: (.status.history | length),
  rollbackAware: (if (.spec.syncPolicy.automated // {} | has("rollbackAware"))
                  then .spec.syncPolicy.automated.rollbackAware else "inherited" end)
}')
echo "$RESULT"

# The baseline is a state, not a particular revision, so only these four fields are checked.
if ! echo "$RESULT" | jq -e '.sync == "Synced" and .health == "Healthy"
                             and .rolledBack == "" and (.conds | length) == 0' >/dev/null; then
  echo "NOT at the baseline. A broken image still deployed usually means main is stale: check"
  echo "  git -C \"$BARE\" log --oneline -3 main"
  exit 1
fi
# Exactly one entry, not merely at least one: a second entry at the same revision would mean an
# explicit sync ran on top of auto-sync, which is how duplicate rows get into the history panel.
if $HARD && ! echo "$RESULT" | jq -e '.histLen == 1' >/dev/null; then
  echo "NOT at the baseline: a fresh application should have exactly one history entry."
  exit 1
fi
echo "==> at the baseline"
