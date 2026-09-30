#!/usr/bin/env bash
# Exercise policy.prevent-login-without-permissions against a locally running argocd-server.
#
#   export ARGOCD_TEST_PASSWORD=<password for the test account>
#   ./lab.sh backup          # save the current RBAC config. do this first.
#   ./lab.sh run all         # or: ./lab.sh run 9
#   ./lab.sh restore
#
# Exits non-zero if any scenario does not produce the expected verdict.
set -uo pipefail

NS=${NS:-argocd}
SERVER=${SERVER:-localhost:8080}
USER=${ARGOCD_TEST_USER:-alice}
PASS=${ARGOCD_TEST_PASSWORD:-}
BACKUP=${BACKUP:-/tmp/argocd-rbac-cm.backup.json}
WAIT=${WAIT:-20}
PROJECT=${PROJECT:-lab-demo}

pass=0; fail=0

# ---------------------------------------------------------------- login verdict
# Three outcomes, never two. Anything that is not a successful login and not the
# server's own refusal is an ERROR, and an ERROR never counts as a refusal: a
# server that is down or a password that is wrong would otherwise make every
# "expect DENIED" scenario pass for the wrong reason.
classify_login() {
  local out rc
  out=$(argocd login "$SERVER" --plaintext --insecure --username "$USER" --password "$PASS" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo OK; return; fi
  if printf '%s' "$out" | grep -qi 'account has no permissions'; then echo DENIED; return; fi
  if printf '%s' "$out" | grep -qi 'invalid username or password'; then echo BADCREDS; return; fi
  echo "ERROR|$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-140)"
}

wait_for() { # $1=expected verdict -> prints the final verdict
  local deadline=$((SECONDS + WAIT)) v
  while [ $SECONDS -lt $deadline ]; do
    v=$(classify_login)
    [ "$v" = "$1" ] && { echo "$v"; return; }
    case "$v" in ERROR*|BADCREDS) echo "$v"; return ;; esac   # do not spin on a broken setup
    sleep 1
  done
  echo "$v"
}

# ---------------------------------------------------------------- config
rbac() { # $1=policy.csv $2=matchMode $3=policy.default $4=flag
  kubectl -n "$NS" patch cm argocd-rbac-cm --type merge -p "$(python3 - "$@" <<'PY'
import json, sys
csv, mode, default, flag = sys.argv[1:5]
print(json.dumps({"data": {"policy.csv": csv, "policy.matchMode": mode,
                           "policy.default": default,
                           "policy.prevent-login-without-permissions": flag}}))
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

# Force an observed transition before every scenario, so a verdict can never be
# inherited from the previous one: drive to the opposite verdict first and wait
# for it, then apply the scenario.
barrier() { # $1=the verdict the scenario expects
  if [ "$1" = OK ]; then proj_role ""; rbac "" "" "" "true";  wait_for DENIED >/dev/null
  else                   proj_role ""; rbac "" "" "" "false"; wait_for OK     >/dev/null
  fi
}

# ---------------------------------------------------------------- preflight
preflight() {
  [ -n "$PASS" ] || { echo "ARGOCD_TEST_PASSWORD is not set"; return 1; }
  command -v argocd >/dev/null || { echo "argocd CLI not on PATH (make cli-local)"; return 1; }

  local v
  # Everything below rewrites argocd-rbac-cm, so refuse to start without a backup.
  [ -s "$BACKUP" ] || { echo "no backup at $BACKUP. Run '$0 backup' first"; return 1; }

  # Probe the credentials before changing anything. A wrong password looks the same
  # whatever the policy says, so this needs no setup and leaves the config alone.
  v=$(classify_login)
  case "$v" in
    OK|DENIED) ;;
    BADCREDS) echo "preflight: wrong password for $USER. Set ARGOCD_TEST_PASSWORD, or reset it with:"
              echo "           argocd account update-password --account $USER --new-password <pw>"
              return 1 ;;
    *) echo "preflight: cannot reach $SERVER -> $v"; return 1 ;;
  esac

  proj_role ""; rbac "" "" "" "false"
  v=$(wait_for OK)
  [ "$v" = OK ] || { echo "preflight: cannot log in as $USER with the flag off -> $v"; return 1; }

  # If a deliberately wrong password logs in, the server is running with
  # --disable-auth and every scenario below would pass for the wrong reason.
  local saved=$PASS
  PASS="definitely-not-the-password-$$"
  v=$(classify_login); PASS=$saved
  [ "$v" = OK ] && { echo "preflight: a wrong password was accepted. Restart with ARGOCD_E2E_DISABLE_AUTH=false"; return 1; }

  # If turning the flag on does not refuse an account with no rules, the binary
  # predates the feature, or policy.default is granting everyone something.
  rbac "" "" "" "true"
  v=$(wait_for DENIED)
  [ "$v" = DENIED ] || { echo "preflight: the flag had no effect -> $v. Is this build from the PR branch?"; return 1; }

  echo "preflight ok: auth is enforced and the flag is live"
}

# ---------------------------------------------------------------- scenarios
ALLOW='p, alice, applications, get, */*, allow'
ANCH='p, alice, applications, get, ^default/.*$, allow'

setup() { case "$1" in
 1)  DESC="flag off, no permissions";                  EXPECT=OK;     proj_role ""; rbac "" "" "" "false" ;;
 2)  DESC="flag on, no permissions";                   EXPECT=DENIED; proj_role ""; rbac "" "" "" "true" ;;
 3)  DESC="direct allow";                              EXPECT=OK;     proj_role ""; rbac "$ALLOW" "" "" "true" ;;
 4)  DESC="allow + blanket deny, same subject";        EXPECT=DENIED; proj_role ""; rbac "$ALLOW"$'\n''p, alice, *, *, *, deny' "" "" "true" ;;
 5)  DESC="allow + a deny on another resource";        EXPECT=OK;     proj_role ""; rbac "$ALLOW"$'\n''p, alice, clusters, get, *, deny' "" "" "true" ;;
 6)  DESC="allow through a role binding";              EXPECT=OK;     proj_role ""; rbac 'g, alice, role:viewer'$'\n''p, role:viewer, applications, get, */*, allow' "" "" "true" ;;
 7)  DESC="role binding + blanket deny on the user";   EXPECT=DENIED; proj_role ""; rbac 'g, alice, role:viewer'$'\n''p, role:viewer, applications, get, */*, allow'$'\n''p, alice, *, *, *, deny' "" "" "true" ;;
 8)  DESC="glob character class in the object";        EXPECT=OK;     proj_role ""; rbac 'p, alice, applications, get, default/app-[a-z]*, allow' "" "" "true" ;;
 9)  DESC="regex mode, anchored object pattern";       EXPECT=OK;     proj_role ""; rbac "$ANCH" "regex" "" "true" ;;
 10) DESC="regex mode, ^\$ deny cancels nothing";       EXPECT=OK;     proj_role ""; rbac "$ANCH"$'\n''p, alice, ^$, ^$, ^$, deny' "regex" "" "true" ;;
 11) DESC="regex mode, .* deny cancels everything";    EXPECT=DENIED; proj_role ""; rbac "$ANCH"$'\n''p, alice, .*, .*, .*, deny' "regex" "" "true" ;;
 12) DESC="policy.default grants everyone something";  EXPECT=OK;     proj_role ""; rbac "" "" "role:readonly" "true" ;;
 13) DESC="permissions only from a project role";      EXPECT=OK;     rbac "" "" "" "true"; proj_role "p, proj:$PROJECT:dev, applications, sync, $PROJECT/*, allow" ;;
 14) DESC="project role + blanket deny on the user";   EXPECT=DENIED; rbac 'p, alice, *, *, *, deny' "" "" "true"; proj_role "p, proj:$PROJECT:dev, applications, sync, $PROJECT/*, allow" ;;
 15) DESC="project role whose policies are all deny";  EXPECT=OK;     rbac "" "" "" "true"; proj_role "p, proj:$PROJECT:dev, applications, sync, $PROJECT/*, deny" ;;
 *) echo "unknown scenario $1" >&2; return 1 ;;
esac }

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
    # Refuse to overwrite a good backup with lab state. Running backup again, after a run has already
    # rewritten the ConfigMap, would otherwise destroy the only copy of the real policy.
    if kubectl -n "$NS" get cm argocd-rbac-cm -o jsonpath='{.data}' | grep -q 'reportNoPermissions\|prevent-login-without-permissions'; then
      echo "refusing: argocd-rbac-cm still holds lab state. Run '$0 restore' first, or point BACKUP elsewhere."
      exit 1
    fi
    kubectl -n "$NS" get cm argocd-rbac-cm -o json > "$BACKUP" && echo "saved $BACKUP" ;;
  restore)
    # A merge patch that also nulls out every key the backup did not have, so the keys
    # this script adds are removed rather than left behind. Applying the saved manifest
    # instead would carry its stale resourceVersion and conflict once the CM has moved.
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
  classify) classify_login ;;
  preflight) preflight ;;
  run)
    preflight || exit 1
    if [ "${2:-all}" = all ]; then for i in $(seq 1 15); do scenario "$i"; done
    else scenario "$2"; fi
    echo "  ----"; echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ] ;;
  *) sed -n '2,10p' "$0" ;;
esac
