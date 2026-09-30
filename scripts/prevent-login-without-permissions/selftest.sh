#!/usr/bin/env bash
# Verifies lab.sh cannot report a false result. Runs entirely against stubbed
# argocd/kubectl binaries, so it needs no cluster and no Argo CD.
set -uo pipefail
cd "$(dirname "$0")"

STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
export PATH="$STUB:$PATH"
export ARGOCD_TEST_PASSWORD=correct-horse
export WAIT=3
pass=0; fail=0

cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
# Only the RBAC patch matters: record the flag so the argocd stub can react to it.
echo "$*" >> "$STUB_STATE/kubectl.calls"
for a in "$@"; do case "$a" in *prevent-login-without-permissions*)
  printf '%s' "$a" | grep -q '"policy.prevent-login-without-permissions": *"true"' \
    && echo true > "$STUB_STATE/flag" || echo false > "$STUB_STATE/flag" ;;
esac; done
exit 0
EOF

cat > "$STUB/argocd" <<'EOF'
#!/usr/bin/env bash
mode=$(cat "$STUB_STATE/mode"); flag=$(cat "$STUB_STATE/flag" 2>/dev/null || echo false)
pw=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = "--password" ] && { j=$((i+1)); pw="${!j}"; }; done
case "$mode" in
  down)     echo "FATA[0000] rpc error: code = Unavailable desc = connection error: dial tcp [::1]:8080: connect: connection refused" >&2; exit 1 ;;
  badcreds) echo "FATA[0000] rpc error: code = Unauthenticated desc = Invalid username or password" >&2; exit 1 ;;
  noauth)   exit 0 ;;
  noflag)   [ "$pw" = "correct-horse" ] && exit 0
            echo "FATA[0000] rpc error: code = Unauthenticated desc = Invalid username or password" >&2; exit 1 ;;
  normal)   [ "$pw" != "correct-horse" ] && { echo "FATA[0000] rpc error: code = Unauthenticated desc = Invalid username or password" >&2; exit 1; }
            [ "$flag" = true ] && { echo "FATA[0000] rpc error: code = PermissionDenied desc = account has no permissions; contact your administrator" >&2; exit 1; }
            exit 0 ;;
esac
EOF
chmod +x "$STUB/kubectl" "$STUB/argocd"
export STUB_STATE=$STUB; echo false > "$STUB/flag"
export BACKUP="$STUB/backup.json"; echo '{"data":{"policy.csv":""}}' > "$BACKUP"

check() { # $1=label $2=expected $3=actual
  if [ "$3" = "$2" ]; then printf '  ok   %-52s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL %-52s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
check_contains() {
  if printf '%s' "$3" | grep -qi -- "$2"; then printf '  ok   %-52s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %-52s expected to mention %q, got %q\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

echo "classification"
echo normal > "$STUB/mode"; echo false > "$STUB/flag"
check "a successful login is OK"                    OK     "$(./lab.sh classify)"
echo true > "$STUB/flag"
check "the server's own refusal is DENIED"          DENIED "$(./lab.sh classify)"

# The whole point: a broken environment must never look like a refusal, or every
# scenario expecting DENIED would pass for the wrong reason.
echo down > "$STUB/mode"
check "a server that is down is not a refusal"      ERROR  "$(./lab.sh classify | cut -d'|' -f1)"
echo badcreds > "$STUB/mode"
check "a wrong password is its own outcome, not a refusal" BADCREDS "$(./lab.sh classify)"

echo
echo "preflight"
echo normal > "$STUB/mode"
check_contains "passes when auth is on and the flag works" "preflight ok" "$(./lab.sh preflight 2>&1)"
echo noauth > "$STUB/mode"
check_contains "catches a server running with auth disabled" "wrong password was accepted" "$(./lab.sh preflight 2>&1)"
echo noflag > "$STUB/mode"
check_contains "catches a build without the feature"  "flag had no effect" "$(./lab.sh preflight 2>&1)"
echo down > "$STUB/mode"
check_contains "catches a server that is not running" "cannot reach" "$(./lab.sh preflight 2>&1)"
echo badcreds > "$STUB/mode"
check_contains "catches a wrong password"             "wrong password for" "$(./lab.sh preflight 2>&1)"

# A wrong password must be caught before any configuration is touched, otherwise a
# typo leaves the live RBAC config wiped and the run never gets to restore it.
echo badcreds > "$STUB/mode"; : > "$STUB/kubectl.calls"
./lab.sh preflight >/dev/null 2>&1
check "and touches no configuration first"          0      "$(grep -c . "$STUB/kubectl.calls")"

# And it refuses to mutate at all when there is nothing to restore from.
echo normal > "$STUB/mode"; mv "$BACKUP" "$BACKUP.hidden"; : > "$STUB/kubectl.calls"
out=$(./lab.sh preflight 2>&1); mv "$BACKUP.hidden" "$BACKUP"
check_contains "refuses to run without a backup"      "backup" "$out"
check "and touches no configuration then either"    0      "$(grep -c . "$STUB/kubectl.calls")"
ARGOCD_TEST_PASSWORD= check_contains "catches a missing password" "not set" "$(ARGOCD_TEST_PASSWORD= ./lab.sh preflight 2>&1)"

echo
echo "a scenario run refuses to start on a bad setup"
echo noauth > "$STUB/mode"
out=$(./lab.sh run 2 2>&1); rc=$?
check "run exits non-zero"                          1      "$rc"
check_contains "and runs no scenarios"              "wrong password was accepted" "$out"

echo
echo "the expected verdicts agree with the enforcer"
# Guards the other half: a wrong EXPECT value would make lab.sh fail on correct
# behaviour, or pass on broken behaviour. The oracle derives each verdict from the
# real enforcer, so the table cannot drift away from the implementation.
#
# Failing to RUN the oracle is reported separately from the oracle DISAGREEING.
# Collapsing the two would be the same mistake this whole harness exists to avoid.
if ! command -v go >/dev/null; then
  printf '  skip %-52s\n' "go not on PATH, cannot check EXPECT values"
else
  repo=$(cd ../.. && pwd)
  oracle_err=$(mktemp)
  oracle=$(cd "$repo" && go run -mod=mod scripts/prevent-login-without-permissions/verify-expectations.go 2>"$oracle_err")
  oracle_rc=$?
  table=$(grep -oE '^ *[0-9]+\) +DESC=.*EXPECT=[A-Z]+' lab.sh | sed -E 's/^ *([0-9]+)\).*EXPECT=([A-Z]+).*/\1 \2/')
  n_oracle=$(printf '%s' "$oracle" | grep -c . )
  n_table=$(printf '%s' "$table" | grep -c . )

  if [ "$oracle_rc" -ne 0 ] || [ "$n_oracle" -eq 0 ]; then
    printf '  FAIL %-52s\n' "could not run the oracle (rc=$oracle_rc, $n_oracle lines)"
    sed 's/^/       /' "$oracle_err" | head -12
    fail=$((fail+1))
  elif [ "$n_table" -eq 0 ]; then
    printf '  FAIL %-52s\n' "could not read the EXPECT values out of lab.sh"
    fail=$((fail+1))
  elif [ "$n_oracle" -ne "$n_table" ]; then
    printf '  FAIL %-52s\n' "oracle has $n_oracle scenarios, lab.sh has $n_table"
    fail=$((fail+1))
  elif [ "$oracle" = "$table" ]; then
    printf '  ok   %-52s %s\n' "every EXPECT value matches the enforcer" "$n_table checked"
    pass=$((pass+1))
  else
    printf '  FAIL %-52s\n' "EXPECT values disagree with the enforcer"
    diff <(printf '%s\n' "$oracle") <(printf '%s\n' "$table") | sed 's/^/       /'
    fail=$((fail+1))
  fi
  rm -f "$oracle_err"
fi

echo
echo "  ----"; echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
