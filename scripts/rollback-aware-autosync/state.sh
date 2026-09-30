#!/usr/bin/env bash
# Print everything the #9570 manual tests need to read after a step. One command per "read" row in
# the case tables, so no row asks you to hunt through the UI or assemble a jq filter.
#
#   ./state.sh
#
# The pause line reproduces what the UI renders in the SYNC STATUS tile, including the multi-source
# rolledBackRevisions form, so a disagreement between this and the UI is a real finding.
set -euo pipefail

NS=${NS:-argocd}
APP=${APP:-rollback-demo}

kubectl -n "$NS" get app "$APP" -o json | jq -r '
  (if (.status.rolledBackRevisions // [] | length) > 0 then .status.rolledBackRevisions
   elif (.status.rolledBackRevision // "") != "" then [.status.rolledBackRevision]
   else [] end) as $rb
  | (.status.history // []) as $h
  # The // operator falls through on false as well as null, so a per-app false would read as
  # inherited. has() is the only way to tell an absent field from one set to false.
  | (.spec.syncPolicy.automated // {}) as $auto
  | "sync:          \(.status.sync.status) at \(.status.sync.revision[0:7])",
    "health:        \(.status.health.status)",
    "auto sync:     \(if (.spec.syncPolicy.automated // null) != null
                   and .spec.syncPolicy.automated.enabled != false
                   then "enabled" else "not enabled" end)",
    "rollbackAware: \(if ($auto | has("rollbackAware"))
                     then ($auto.rollbackAware | tostring)
                     else "inherited from argocd-cm" end)",
    "pause line:    \(if ($rb | length) > 0
                   then "Auto sync skips rolled back revision \($rb | map(.[0:7]) | join(", "))"
                   else "(absent)" end)",
    "record:        \(if ($rb | length) > 0 then ($rb | map(.[0:7]) | join(", "))
                     else "(empty)" end)"
      + " (plural field: \(.status.rolledBackRevisions // [] | length) entries)",
    "conds:         \(if ([.status.conditions[]?] | length) > 0
                   then [.status.conditions[].type] | join(", ") else "(none)" end)",
    "last sync:     \(if ($h | length) > 0
                   then "id \($h[-1].id)  \($h[-1].revision[0:7])"
                        + "  automated=\($h[-1].initiatedBy.automated // false)"
                   else "(no history)" end)",
    "history:       \($h | length) entries",
    "reconciled:    \(.status.reconciledAt // "(never)")"
'
