#!/usr/bin/env bash
# Exercise policy.reportNoPermissions against a locally running argocd-server.
#
#   export ARGOCD_TEST_PASSWORD=<password for the test account>
#   ./lab.sh backup          # save the current RBAC config. do this first.
#   ./lab.sh run all         # or: ./lab.sh run 8
#   ./lab.sh restore
#
# Nothing here is ever refused a login. The observable is the noPermissions field on
# /api/v1/session/userinfo, so the verdicts are REPORTED and SILENT rather than DENIED and OK.
# Exits non-zero if any scenario does not produce the expected verdict.
set -uo pipefail

NS=${NS:-argocd}
BASE=${BASE:-http://localhost:8080}
USER=${ARGOCD_TEST_USER:-alice}
PASS=${ARGOCD_TEST_PASSWORD:-}
BACKUP=${BACKUP:-/tmp/argocd-rbac-cm.report.backup.json}
WAIT=${WAIT:-20}
PROJECT=${PROJECT:-lab-demo}
KEY=policy.reportNoPermissions

pass=0; fail=0

# ---------------------------------------------------------------- verdict
# Four outcomes, never two. A server that is down or a wrong password must never be mistaken for a
# report, or every scenario expecting REPORTED would pass for the wrong reason.
classify() {
  local payload resp tok info
  payload=$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$USER" "$PASS")
  resp=$(curl -s --max-time 10 -X POST "$BASE/api/v1/session" -H 'Content-Type: application/json' -d "$payload" 2>&1)
  if [ -z "$resp" ]; then echo "ERROR|no response from $BASE"; return; fi

  tok=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')
  if [ -z "$tok" ]; then
    printf '%s' "$resp" | grep -qi 'invalid username or password' && { echo BADCREDS; return; }
    echo "ERROR|$(printf '%s' "$resp" | tr -d '\n' | cut -c1-140)"; return
  fi

  info=$(curl -s --max-time 10 -H "Authorization: Bearer $tok" "$BASE/api/v1/session/userinfo" 2>&1)
  printf '%s' "$info" | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception:
    print("ERROR|unparseable userinfo"); raise SystemExit
if not d.get("loggedIn"):
    print("ERROR|userinfo reports the session is not logged in"); raise SystemExit
# noPermissions is omitempty, so absent means false.
print("REPORTED" if d.get("noPermissions") else "SILENT")'
}

wait_for() { # $1=expected -> prints the final verdict
  local deadline=$((SECONDS + WAIT)) v
  while [ $SECONDS -lt $deadline ]; do
    v=$(classify)
    [ "$v" = "$1" ] && { echo "$v"; return; }
    case "$v" in ERROR*|BADCREDS) echo "$v"; return ;; esac
    sleep 1
  done
  echo "$v"
}

# ---------------------------------------------------------------- config
rbac() { # $1=policy.csv $2=matchMode $3=policy.default $4=report flag
  kubectl -n "$NS" patch cm argocd-rbac-cm --type merge -p "$(python3 - "$@" <<'PY'
import json, sys
csv, mode, default, report = sys.argv[1:5]
print(json.dumps({"data": {"policy.csv": csv, "policy.matchMode": mode,
                           "policy.default": default,
                           "policy.reportNoPermissions": report}}))
PY
)" >/dev/null
}

proj_role() { # $1=policies, newline separated. empty clears the role.
  kubectl -n "$NS" get appproject "$PROJECT" >/dev/null 2>&1 || kubectl -n "$NS" apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: $PROJECT, namespace: $NS}
spec:
  sourceRepos: ['*']
  destinations: [{namespace: '*', server: '*'}]
EOF
  kubectl -n "$NS" patch appproject "$PROJECT" --type merge -p "$(python3 - "${1:-}" "$USER" <<'PY'
import json, sys
pol, user = sys.argv[1], sys.argv[2]
roles = [] if not pol else [{"name": "dev", "policies": pol.split("\n"), "groups": [user]}]
print(json.dumps({"spec": {"roles": roles}}))
PY
)" >/dev/null
}

# Force an observed transition before every scenario, so a verdict is never inherited from the one
# before it.
barrier() { # $1=the verdict the scenario expects
  if [ "$1" = SILENT ]; then proj_role ""; rbac "" "" "" "true";  wait_for REPORTED >/dev/null
  else                       proj_role ""; rbac "" "" "" "false"; wait_for SILENT   >/dev/null
  fi
}

# ---------------------------------------------------------------- preflight
preflight() {
  [ -n "$PASS" ] || { echo "ARGOCD_TEST_PASSWORD is not set"; return 1; }
  [ -s "$BACKUP" ] || { echo "no backup at $BACKUP. Run '$0 backup' first"; return 1; }

  # Probe the credentials before changing anything.
  local v; v=$(classify)
  case "$v" in
    SILENT|REPORTED) ;;
    BADCREDS) echo "preflight: wrong password for $USER. Set ARGOCD_TEST_PASSWORD, or reset it with:"
              echo "           argocd account update-password --account $USER --new-password <pw>"
              return 1 ;;
    *) echo "preflight: cannot reach $BASE -> $v"; return 1 ;;
  esac

  # A wrong password must not produce a session, or every verdict below is meaningless.
  local saved=$PASS; PASS="definitely-not-the-password-$$"
  v=$(classify); PASS=$saved
  [ "$v" = BADCREDS ] || { echo "preflight: a wrong password did not fail ($v). Restart with ARGOCD_E2E_DISABLE_AUTH=false"; return 1; }

  # With the setting on and no rules at all, the server must report. If it does not, the build has no
  # $KEY support, or policy.default is granting everyone something.
  proj_role ""; rbac "" "" "" "true"
  v=$(wait_for REPORTED)
  [ "$v" = REPORTED ] || { echo "preflight: $KEY had no effect -> $v. Is this build from the branch that adds it?"; return 1; }

  echo "preflight ok: auth is enforced and $KEY is live"
}

# ---------------------------------------------------------------- scenarios
ALLOW='p, alice, applications, get, */*, allow'
ANCH='p, alice, applications, get, ^default/.*$, allow'

setup() { case "$1" in
 1)  DESC="setting off, no permissions";                EXPECT=SILENT;   proj_role ""; rbac "" "" "" "false" ;;
 2)  DESC="setting on, no permissions";                 EXPECT=REPORTED; proj_role ""; rbac "" "" "" "true" ;;
 3)  DESC="direct allow";                               EXPECT=SILENT;   proj_role ""; rbac "$ALLOW" "" "" "true" ;;
 4)  DESC="allow + blanket deny, same subject";         EXPECT=REPORTED; proj_role ""; rbac "$ALLOW"$'\n''p, alice, *, *, *, deny' "" "" "true" ;;
 5)  DESC="allow + a deny on another resource";         EXPECT=SILENT;   proj_role ""; rbac "$ALLOW"$'\n''p, alice, clusters, get, *, deny' "" "" "true" ;;
 6)  DESC="allow through a role binding";               EXPECT=SILENT;   proj_role ""; rbac 'g, alice, role:viewer'$'\n''p, role:viewer, applications, get, */*, allow' "" "" "true" ;;
 7)  DESC="role binding + blanket deny on the user";    EXPECT=REPORTED; proj_role ""; rbac 'g, alice, role:viewer'$'\n''p, role:viewer, applications, get, */*, allow'$'\n''p, alice, *, *, *, deny' "" "" "true" ;;
 8)  DESC="glob character class in the object";         EXPECT=SILENT;   proj_role ""; rbac 'p, alice, applications, get, default/app-[a-z]*, allow' "" "" "true" ;;
 9)  DESC="regex mode, anchored object pattern";        EXPECT=SILENT;   proj_role ""; rbac "$ANCH" "regex" "" "true" ;;
 10) DESC="regex mode, ^\$ deny cancels nothing";        EXPECT=SILENT;   proj_role ""; rbac "$ANCH"$'\n''p, alice, ^$, ^$, ^$, deny' "regex" "" "true" ;;
 11) DESC="regex mode, .* deny cancels everything";     EXPECT=REPORTED; proj_role ""; rbac "$ANCH"$'\n''p, alice, .*, .*, .*, deny' "regex" "" "true" ;;
 12) DESC="policy.default grants everyone something";   EXPECT=SILENT;   proj_role ""; rbac "" "" "role:readonly" "true" ;;
 13) DESC="project role only (KNOWN GAP)";              EXPECT=REPORTED; rbac "" "" "" "true"; proj_role "p, proj:$PROJECT:dev, applications, sync, $PROJECT/*, allow" ;;
 14) DESC="project role + blanket deny on the user";    EXPECT=REPORTED; rbac 'p, alice, *, *, *, deny' "" "" "true"; proj_role "p, proj:$PROJECT:dev, applications, sync, $PROJECT/*, allow" ;;
 15) DESC="project role all deny (KNOWN GAP)";          EXPECT=REPORTED; rbac "" "" "" "true"; proj_role "p, proj:$PROJECT:dev, applications, sync, $PROJECT/*, deny" ;;
 *) echo "unknown scenario $1" >&2; return 1 ;;
esac }

# Scenarios 13 and 15 pass by recording behaviour that is WRONG. HasAnyPermission does not consult
# AppProject roles, so a user whose only grants come from a project role is told they have none.
# They are here so the gap is visible and so closing it shows up as a change in this table.

scenario() {
  DESC=; EXPECT=
  setup "$1" || return 1
  barrier "$EXPECT"
  setup "$1"
  local got; got=$(wait_for "$EXPECT")
  if [ "$got" = "$EXPECT" ]; then
    printf '  ok   %-2s %-42s %s\n' "$1" "$DESC" "$got"; pass=$((pass+1))
  else
    printf '  FAIL %-2s %-42s expected %s, got %s\n' "$1" "$DESC" "$EXPECT" "$got"; fail=$((fail+1))
  fi
}

case "${1:-}" in
  backup)
    if kubectl -n "$NS" get cm argocd-rbac-cm -o jsonpath='{.data}' | grep -q 'reportNoPermissions\|prevent-login-without-permissions'; then
      echo "refusing: argocd-rbac-cm still holds lab state. Run '$0 restore' first, or point BACKUP elsewhere."
      exit 1
    fi
    kubectl -n "$NS" get cm argocd-rbac-cm -o json > "$BACKUP" && echo "saved $BACKUP" ;;
  restore)
    restore_patch=$(python3 - "$BACKUP" "$(kubectl -n "$NS" get cm argocd-rbac-cm -o jsonpath='{.data}')" <<'RESTORE'
import json, sys
saved = json.load(open(sys.argv[1]))
saved = saved.get("data", saved) or {}
live = json.loads(sys.argv[2] or "{}")
patch = dict(saved)
for k in live:
    if k not in saved:
        patch[k] = None
print(json.dumps({"data": patch}))
RESTORE
)
    kubectl -n "$NS" patch cm argocd-rbac-cm --type merge -p "$restore_patch" >/dev/null \
      && proj_role "" && echo "restored from $BACKUP" ;;
  classify)  classify ;;
  preflight) preflight ;;
  run)
    preflight || exit 1
    if [ "${2:-all}" = all ]; then for i in $(seq 1 15); do scenario "$i"; done
    else scenario "$2"; fi
    echo "  ----"; echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ] ;;
  *) sed -n '2,12p' "$0" ;;
esac
