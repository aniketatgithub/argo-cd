#!/usr/bin/env bash
# Verifies lab.sh cannot report a false result. Runs against a stubbed HTTP API, so it needs no
# cluster and no Argo CD.
set -uo pipefail
cd "$(dirname "$0")"

STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
export PATH="$STUB:$PATH"
export STUB_STATE=$STUB
export ARGOCD_TEST_PASSWORD=correct-horse
export BACKUP="$STUB/backup.json"; echo '{"data":{"policy.csv":""}}' > "$BACKUP"
export WAIT=3
pass=0; fail=0

cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_STATE/kubectl.calls"
for a in "$@"; do case "$a" in *reportNoPermissions*)
  printf '%s' "$a" | grep -q '"policy.reportNoPermissions": *"true"' \
    && echo true > "$STUB_STATE/flag" || echo false > "$STUB_STATE/flag" ;;
esac; done
exit 0
EOF

# Stands in for the API. -X POST is the session call, everything else is userinfo.
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
mode=$(cat "$STUB_STATE/mode"); flag=$(cat "$STUB_STATE/flag" 2>/dev/null || echo false)
is_post=false; body=""
for ((i=1;i<=$#;i++)); do
  [ "${!i}" = "-X" ] && { j=$((i+1)); [ "${!j}" = POST ] && is_post=true; }
  [ "${!i}" = "-d" ] && { j=$((i+1)); body="${!j}"; }
done
case "$mode" in
  down) exit 7 ;;   # curl's connection-failed exit, empty stdout
  unparseable) echo "<html>502</html>"; exit 0 ;;
esac
if [ "$is_post" = true ]; then
  if [ "$mode" != noauth ] && ! printf '%s' "$body" | grep -q '"password": *"correct-horse"'; then
    echo '{"error":"Invalid username or password","code":16}'; exit 0
  fi
  echo '{"token":"stub-token"}'; exit 0
fi
if [ "$mode" = noflag ] || [ "$flag" != true ]; then
  echo '{"loggedIn":true,"username":"alice","iss":"argocd"}'
else
  echo '{"loggedIn":true,"username":"alice","iss":"argocd","noPermissions":true}'
fi
EOF
chmod +x "$STUB/kubectl" "$STUB/curl"; echo false > "$STUB/flag"

check() { if [ "$3" = "$2" ]; then printf '  ok   %-54s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL %-54s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
check_contains() { if printf '%s' "$3" | grep -qi -- "$2"; then printf '  ok   %-54s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %-54s expected %q, got %q\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

echo "verdicts"
echo normal > "$STUB/mode"; echo false > "$STUB/flag"
check "an absent noPermissions field is SILENT"       SILENT   "$(./lab.sh classify)"
echo true > "$STUB/flag"
check "noPermissions true is REPORTED"                REPORTED "$(./lab.sh classify)"
echo down > "$STUB/mode"
check "an unreachable server is not a report"         ERROR    "$(./lab.sh classify | cut -d'|' -f1)"
echo unparseable > "$STUB/mode"
check "a non-JSON response is not a report"           ERROR    "$(./lab.sh classify | cut -d'|' -f1)"
echo normal > "$STUB/mode"; ARGOCD_TEST_PASSWORD=wrong \
check "a wrong password is its own outcome"           BADCREDS "$(ARGOCD_TEST_PASSWORD=wrong ./lab.sh classify)"

echo
echo "preflight"
echo normal > "$STUB/mode"
check_contains "passes when auth is on and the key works"  "preflight ok" "$(./lab.sh preflight 2>&1)"
echo noauth > "$STUB/mode"
check_contains "catches a server with auth disabled"       "wrong password did not fail" "$(./lab.sh preflight 2>&1)"
echo noflag > "$STUB/mode"
check_contains "catches a build without the setting"       "had no effect" "$(./lab.sh preflight 2>&1)"
echo down > "$STUB/mode"
check_contains "catches a server that is not running"      "cannot reach" "$(./lab.sh preflight 2>&1)"
echo normal > "$STUB/mode"; : > "$STUB/kubectl.calls"
check_contains "catches a wrong password"                  "wrong password for" "$(ARGOCD_TEST_PASSWORD=wrong ./lab.sh preflight 2>&1)"
check "and touches no configuration first"            0 "$(grep -c . "$STUB/kubectl.calls")"
mv "$BACKUP" "$BACKUP.hidden"; : > "$STUB/kubectl.calls"
out=$(./lab.sh preflight 2>&1); mv "$BACKUP.hidden" "$BACKUP"
check_contains "refuses to run without a backup"           "backup" "$out"
check "and touches no configuration then either"      0 "$(grep -c . "$STUB/kubectl.calls")"

echo
echo "the expected verdicts agree with the implementation"
if ! command -v go >/dev/null; then
  printf '  skip %-54s\n' "go not on PATH"
else
  repo=$(cd ../.. && pwd); err=$(mktemp)
  oracle=$(cd "$repo" && go run scripts/report-no-permissions/verify-expectations.go 2>"$err"); rc=$?
  table=$(grep -oE '^ *[0-9]+\) +DESC=.*EXPECT=[A-Z]+' lab.sh | sed -E 's/^ *([0-9]+)\).*EXPECT=([A-Z]+).*/\1 \2/')
  n_o=$(printf '%s' "$oracle" | grep -c .); n_t=$(printf '%s' "$table" | grep -c .)
  if [ "$rc" -ne 0 ] || [ "$n_o" -eq 0 ]; then
    printf '  FAIL %-54s\n' "could not run the oracle (rc=$rc, $n_o lines)"; sed 's/^/       /' "$err" | head -8; fail=$((fail+1))
  elif [ "$n_o" -ne "$n_t" ]; then
    printf '  FAIL %-54s\n' "oracle has $n_o scenarios, lab.sh has $n_t"; fail=$((fail+1))
  elif [ "$oracle" = "$table" ]; then
    printf '  ok   %-54s %s\n' "every EXPECT value matches" "$n_t checked"; pass=$((pass+1))
  else
    printf '  FAIL %-54s\n' "EXPECT values disagree"; diff <(printf '%s\n' "$oracle") <(printf '%s\n' "$table") | sed 's/^/       /'; fail=$((fail+1))
  fi
  rm -f "$err"
fi

echo; echo "  ----"; echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
