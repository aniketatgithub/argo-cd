# Manual test guide: rollback-aware auto-sync (#9570)

Branch: `9570-rollback-aware-auto-sync`.

This guide covers what automated tests cannot reach: how the feature looks and behaves in the UI,
how the two-tier setting travels from `argocd-cm` through the API to the browser, and how auto-sync
and self-heal behave on a live cluster over time.

Automated coverage per case, so you know which cases are a second opinion and which are the only
check that exists. Line numbers are in `test/e2e/app_autosync_test.go` and
`controller/appcontroller_test.go`.

| Case | e2e | Unit |
|---|---|---|
| 1 Fix forward | `TestAutoSyncRollbackAware` (:290) | "clears the record and syncs once the desired revision moves on" |
| 2 Self-heal paused | `TestAutoSyncRollbackAwarePausesSelfHeal` (:335) | none |
| 3 Per-app override off | none | "per-application opt-out overrides the instance-wide setting" |
| 4 Manual sync while paused | `TestAutoSyncRollbackAwareManualSyncClearsRecord` (:398) | none directly |
| 5 Two rollbacks | `TestAutoSyncRollbackAwareSecondRollbackReplacesRecord` (:428) | "a later rollback overwrites the record" (`controller/state_test.go:1417`) |
| 6 Instance off, per-app on | none | "per-application opt-in works without the instance-wide setting" |

Two more e2e tests cover behavior that is not one of the six cases:
`TestAutoSyncRollbackAwareRevertClearsRecord` (:311) for repair by revert, and
`TestAutoSyncRollbackRejectedWhenNotRollbackAware` (:476) for the feature being off everywhere. That
is a different resolution path from the per-application `false` in case 3.

What no automated test can reach, and what these six cases exist for: every UI assertion (the pause
line, the warning chip, the two rollback dialog wordings), the `--rollback-aware` CLI flag surviving
a round trip through the CRD, and `rollbackAwareAutoSyncEnabled` reaching the browser.

## 1. Preflight

### 1.1 The CRD must carry the new fields

Do this check first, every time, on any cluster you have not used for this feature before.

```bash
kubectl get crd applications.argoproj.io -o json \
  | jq -r '.spec.versions[0].schema.openAPIV3Schema.properties as $s
           | "status.rolledBackRevision:   \($s.status.properties | has("rolledBackRevision"))",
             "status.rolledBackRevisions:  \($s.status.properties | has("rolledBackRevisions"))",
             "automated.rollbackAware:     \($s.spec.properties.syncPolicy
                                            .properties.automated.properties
                                            | has("rollbackAware"))"'
```

All three must print `true`. If any prints `false`, apply the branch CRD:

```bash
kubectl apply --server-side --force-conflicts -f manifests/crds/application-crd.yaml
```

> [!WARNING]
> Kubernetes silently prunes unknown fields from structural CRD schemas. With a pre-v3.6 Application
> CRD, all three fields are dropped on write with no error anywhere. The rollback is then accepted
> and auto-sync immediately re-deploys the revision you rolled back from, which is worse than the
> old hard rejection. Every symptom points at the controller and none of them points at the CRD,
> so check the CRD before you debug anything else.

### 1.2 Local stack

```bash
make start-local
```

`start-local` depends on `cli-local`, so it rebuilds `./dist/argocd` and picks up your working tree.
If you already have goreman running from before a code change, restart the `controller` process.

The UI is on `http://localhost:4000`, the API server on `http://localhost:8080`. Log in to both the
browser and the CLI (`argocd login localhost:8080`) before you start.

### 1.3 Namespaced cluster registrations

If the in-cluster destination is registered in namespaced mode, the target namespace has to be in
its `namespaces` list or every comparison fails with `namespace "rollback-demo" ... is not managed`.

```bash
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster -o json \
  | jq -r '.items[] | "\(.metadata.name)  \(.data.namespaces | @base64d // "all namespaces")"'
```

To add the namespace to an existing namespaced registration, patch the secret instead of deleting
it, which preserves whatever else you had registered:

```bash
NSLIST=$(kubectl -n argocd get secret in-cluster-namespaced \
  -o jsonpath='{.data.namespaces}' | base64 -d)
kubectl -n argocd patch secret in-cluster-namespaced --type merge \
  -p "{\"stringData\":{\"namespaces\":\"$NSLIST,rollback-demo\"}}"
```

### 1.4 The CLI must be the branch build

A released `argocd` on your `PATH` will reject the new flag outright:

```console
$ argocd app set rollback-demo --rollback-aware=false
Error: unknown flag: --rollback-aware
```

Check which binary you are about to use, and put `dist` in front of `PATH` for the session:

```bash
command -v argocd                       # /opt/homebrew/bin/argocd is the wrong one
export PATH="$PWD/dist:$PATH"           # from the repo root, after make start-local
argocd version --client --short         # must print v3.6.0+<sha>, not v3.4.x
```

`make start-local` rebuilds `./dist/argocd`, so the binary is there; only `PATH` order is wrong.
This matters beyond the one flag. An older client cannot send
`spec.syncPolicy.automated.rollbackAware` at all, so `argocd app create` quietly produces an
application without it, which is the same class of failure as the stale CRD in 1.1.

## 2. Fixture

`./rollback-demo.sh` owns a git repo at `$HOME/.argocd-dev/rollback-demo.git` and a working clone
next to it. The repo server runs on the host under `make start-local`, so a `file://` URL works.

| Stage | Manifests | Purpose |
|---|---|---|
| `init` | 1 replica, `nginx:1.27-alpine` | Fresh bare repo plus first commit |
| `v2` | 2 replicas, `nginx:1.27-alpine` | The good revision |
| `v3` | 2 replicas, `nginx:no-such-tag-9570` | The bad revision |
| `v3b` | 3 replicas, `nginx:no-such-tag-9570b` | A second, different bad revision (case 5) |
| `fix` | 2 replicas, `nginx:1.27-alpine` | Repair by revert: same manifests as `v2` |
| `fixfwd` | 3 replicas, `nginx:1.27-alpine` | Repair by fixing forward: manifests differ |
| `log` | | Show the history |
| `url` | | Print the repo URL for `argocd app create` |

`commit_push` is idempotent. Running a stage whose manifests are already committed prints
`already at ..., nothing to push` and pushes nothing, so the desired revision does not move. This is
why case 5 uses `v3b` and not a second `v3`.

Creating the application from scratch:

```bash
kubectl create ns rollback-demo
argocd app create rollback-demo \
  --repo "$(./rollback-demo.sh url)" --path manifests --revision main \
  --dest-server https://kubernetes.default.svc --dest-namespace rollback-demo \
  --sync-policy automated
```

> [!NOTE]
> `argocd app set --sync-option` appends and never replaces, so a second `--sync-option
> CreateNamespace=false` leaves both values in the spec. There is no `unset` flag. Remove one with
> `kubectl -n argocd patch app rollback-demo --type json
> -p '[{"op":"remove","path":"/spec/syncPolicy/syncOptions/0"}]'`.

## 3. Helper commands

`./state.sh` is the readout every case table calls. It prints one line per thing the cases check:

```text
sync:          OutOfSync at 9639592
health:        Healthy
auto sync:     enabled
rollbackAware: inherited from argocd-cm
pause line:    Auto sync skips rolled back revision 9639592
record:        9639592 (plural field: 0 entries)
conds:         AutoSyncPausedWarning
last sync:     id 4  112f220  automated=false
history:       5 entries
reconciled:    2026-09-29T11:59:04Z
```

| Line | What it tells you |
|---|---|
| `sync` | `status.sync.status` and the desired revision the controller resolved |
| `health` | `status.health.status`. A broken image reads `Progressing`, not `Degraded`, for ten minutes |
| `auto sync` | Whether automated sync is on. It stays on through every case; the feature pauses it without switching it off |
| `rollbackAware` | The per-app override, or `inherited from argocd-cm` when the field is absent |
| `pause line` | The exact text the UI shows in the SYNC STATUS tile, or `(absent)`. Reproduced from the same fields the UI reads |
| `record` | `status.rolledBackRevision`, plus how many entries the plural field holds. A single-source app must use the singular field and leave the plural one at `0 entries` |
| `conds` | The condition types on the application, or `(none)` |
| `last sync` | The newest history entry and whether automated sync created it. This is how you tell auto-sync deployed something from you deploying it |
| `history` | How many entries the history holds, which is the row count in the UI history panel |
| `reconciled` | `status.reconciledAt`. A negative result is only meaningful if this moved during the wait |

Saved next to this file as `state.sh`:

```bash
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
```

`argocd app history rollback-demo` lists the history ids with full timestamps. `argocd app rollback`
takes the id as an optional argument: omit it and the CLI resolves `history[len-2]`, the entry
directly below the top one. It refuses with `should have at least two successful deployments` when
only one entry exists, so run `B1` and `B2` first.

> [!NOTE]
> The id is resolved in the client before the request is sent, so a wrong id fails locally with
> `does not have deployment id '<n>' in history`. That is a different failure from the one the cases
> assert, and reading it as a rejected rollback is the easy mistake.

Rolling back to the newest history entry that is not the current desired revision, for ad hoc use.
Case 5 step 5 deliberately does not use this, because it lands on a broken revision:

```bash
argocd app rollback rollback-demo $(argocd app get rollback-demo -o json \
  | jq -r '.status.sync.revision as $d
           | [.status.history[] | select(.revision != $d)] | last | .id')
```


## 4. What the UI shows

| Element | Source | Text |
|---|---|---|
| Pause line in SYNC STATUS | `application-status-panel.tsx:303` | `Auto sync skips rolled back revision <sha> until a new revision is available.` |
| Warning chip | `utils.tsx:1291` maps the `*Warning` suffix to the warning category | `1 Warning` |
| Condition in APP CONDITIONS | controller | `AutoSyncPausedWarning` + `Skipping auto-sync: revision <sha> was rolled back; waiting for a new revision` |
| Rollback dialog, feature on | `application-details.tsx:302` | `Auto-Sync stays enabled and will skip the current revision until ...` |
| Rollback dialog, feature off | `application-details.tsx:299` | `Auto-Sync needs to be disabled in order for rollback to occur.` |

The **pause line** is that first row: a line inside the SYNC STATUS tile, behind a pause icon,
directly under `Auto sync is enabled.`. It is present only while a revision is recorded, so the
tables below say "the pause line is gone" to mean the record was cleared. Every case that mentions
it means this one line.

It renders from `status.rolledBackRevision` alone and is not gated on the condition, so it is a
direct read-out of the record. A pause line with no warning chip means the record leaked.

## 5. Doing a rollback in the UI

Every case that reaches the paused state does this once, and the tables write it as a single action.
Here is what that action is, step by step.

| # | Action | What you should see |
|---|---|---|
| 1 | Open the application, then click **History and rollback** in the top toolbar (the clock icon) | A panel listing every past deployment. The item is disabled until the application has synced at least once |
| 2 | Look at the order | Newest deployment at the top. The panel reverses `status.history`, so the top row is the revision that is deployed right now |
| 3 | Read each row | `Revision: <sha>`, plus Deployed At, Time to deploy, Initiated by and Active for, and a **⋮** button on the right. The sha needs no expanding; only the Source Parameters block is collapsed |
| 4 | Read the sha in the SYNC STATUS panel | This is the revision you are rolling back **from**. Call it BAD |
| 5 | Walk down the rows and pick the **topmost row whose `Revision` is not BAD** | Skipping every row that repeats BAD, however many there are |
| 6 | Click **⋮** on that row | One menu item. It reads **Rollback**. If it reads **Redeploy** you are on the newest row, which is the current deployment: go down one row |
| 7 | Click **Rollback** | The confirmation dialog, whose wording depends on whether the feature is enabled (section 4) |
| 8 | Click **OK** | The rollback runs |

Step 5 is the one that matters. Rolling back to the revision the source already points at is not a
rollback away from anything, so nothing is recorded, automated sync never pauses, and the case looks
like it ran while testing nothing.

> [!WARNING]
> The **Redeploy** label only tells you about the top row. It cannot help with a repeated sha
> further down, and repeats are common because every sync of the same revision adds its own history
> entry. Compare the sha; do not count rows.

The CLI equivalent computes the target and cannot pick the wrong row:

```bash
argocd app rollback rollback-demo $(argocd app get rollback-demo -o json \
  | jq -r '.status.sync.revision as $d
           | [.status.history[] | select(.revision != $d)] | last | .id')
```

## 6. Baseline

Every case starts here. Run `./restore-baseline.sh` before each one, which recreates the application
so that the deployment history holds a single entry. Section 8 describes both of its modes.

`./state.sh` at the baseline, with the shas and the timestamp varying:

```text
sync:          Synced at <sha>
health:        Healthy
auto sync:     enabled
rollbackAware: inherited from argocd-cm
pause line:    (absent)
record:        (empty) (plural field: 0 entries)
conds:         (none)
last sync:     id 0  <sha>  automated=true
history:       1 entries
reconciled:    <a timestamp>
```

Which revision is deployed is deliberately not part of it: the baseline is a state, not a particular
sha. `history: 1 entries` is part of it, and the script fails if that count is wrong. A second entry
at the same revision would mean an explicit sync ran on top of auto-sync, which is how duplicate
rows reach the history panel and how the wrong row gets clicked at `B4`.

`automated=true` on that single entry says automated sync deployed it, which also confirms the
controller is running before you start a case.

The spec must have `syncPolicy.automated` present and empty, with no `rollbackAware` and no
`selfHeal` key, so that the feature is inherited from `argocd-cm`:

```bash
kubectl -n argocd get app rollback-demo -o jsonpath='{.spec.syncPolicy.automated}'; echo
# {}
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.application\.rollbackAwareAutoSync}'; echo
# true
```


## 7. Cases

Run `./restore-baseline.sh` before every case. Three conventions cover every row below:

| In a row | Means |
|---|---|
| `./state.sh` | The readout from section 3. The Expected column lists only the lines that matter for that step; the others are still printed |
| **REFRESH** | The button in the UI, or `argocd app get rollback-demo --refresh >/dev/null`, which does the same thing |
| **BAD**, **FIX**, **A**, **B** | A sha the step before printed. Write it down; the tables never assume you remember one from an earlier case |

Steps `B1` to `B5` bring the application to the paused state and are written out in full in every
table, so no row needs a lookup. Case 3 stops at `B3`, because its assertion is that the rollback at
`B4` is refused.

### Case 1: fix forward with different manifests

Proves the record is cleared by a real sync through `persistRevisionHistory`.

| # | Action | Expected |
|---|---|---|
| B1 | `./rollback-demo.sh v3` | `pushed <sha>  v3: broken image (the bad one)`. This sha is **BAD** |
| B2 | Click **REFRESH** | No visible result yet |
| B3 | `./state.sh` | `sync: Synced at BAD`, `health: Progressing`, `pause line: (absent)`, `last sync: id <n>  BAD  automated=true` |
| B4 | In the UI: **HISTORY AND ROLLBACK** -> topmost row whose `Revision` is not BAD -> **⋮** -> **Rollback** -> **OK** | Dialog reads `Auto-Sync stays enabled and will skip the current revision until ...`. The rollback is accepted and auto-sync stays on |
| B5 | Click **REFRESH**, then `./state.sh` | `sync: OutOfSync at BAD`, `pause line: Auto sync skips rolled back revision BAD`, `record: BAD (plural field: 0 entries)`, `conds: AutoSyncPausedWarning` |
| 1 | `./rollback-demo.sh fixfwd` | `pushed <sha>  v5: fix forward, three replicas`. This sha is **FIX** |
| 2 | Click **REFRESH** | No visible result yet |
| 3 | `./state.sh` | `sync: Synced at FIX`, `pause line: (absent)`, `record: (empty) (plural field: 0 entries)`, `conds: (none)`, `last sync: id <n>  FIX  automated=true`. `health` is `Progressing` for a few seconds, then `Healthy` |
| 4 | `kubectl -n rollback-demo get deploy rollback-demo -o jsonpath='{.spec.replicas}'; echo` | `3` |
| 5 | In the UI, look at the SYNC STATUS tile and the APP CONDITIONS tile | No `Auto sync skips rolled back revision` line, and no `1 Warning` chip |
| 6 | `./restore-baseline.sh` | Last line `==> at the baseline` |

`automated=true` at step 3 is the part that matters: auto-sync deployed FIX by itself, which is what
clearing the record is for.

### Case 2: self-heal stays paused

Checks the self-heal claim in `docs/user-guide/auto_sync.md`, which has never been observed live.

| # | Action | Expected |
|---|---|---|
| P1 | `argocd app set rollback-demo --self-heal` | `application 'rollback-demo' updated` |
| B1 | `./rollback-demo.sh v3` | `pushed <sha>  v3: broken image (the bad one)`. This sha is **BAD** |
| B2 | Click **REFRESH** | No visible result yet |
| B3 | `./state.sh` | `sync: Synced at BAD`, `health: Progressing`, `pause line: (absent)` |
| B4 | In the UI: **HISTORY AND ROLLBACK** -> topmost row whose `Revision` is not BAD -> **⋮** -> **Rollback** -> **OK** | Dialog reads `Auto-Sync stays enabled and will skip the current revision until ...`. The rollback is accepted |
| B5 | Click **REFRESH**, then `./state.sh` | `sync: OutOfSync at BAD`, `pause line: Auto sync skips rolled back revision BAD`, `record: BAD (plural field: 0 entries)`, `conds: AutoSyncPausedWarning` |
| 1 | `kubectl -n rollback-demo scale deploy rollback-demo --replicas 7` | `deployment.apps/rollback-demo scaled` |
| 2 | Run the watch loop below for 60 seconds | Every line reads `7 replicas`, and the timestamp changes at least once. **This is the assertion** |
| 3 | `./state.sh` | `sync: OutOfSync at BAD`, `record: BAD (plural field: 0 entries)`, `conds: AutoSyncPausedWarning`. Unchanged from B5 |
| 4 | `./rollback-demo.sh fixfwd` | `pushed <sha>  v5: fix forward, three replicas`. This sha is **FIX** |
| 5 | Click **REFRESH**, then `./state.sh` | `sync: Synced at FIX`, `pause line: (absent)`, `record: (empty) (plural field: 0 entries)`, `conds: (none)` |
| 6 | `kubectl -n rollback-demo get deploy rollback-demo -o jsonpath='{.spec.replicas}'; echo` | `3`, so self-heal started working again |
| 7 | `argocd app set rollback-demo --self-heal=false` | `application 'rollback-demo' updated` |
| 8 | `./restore-baseline.sh` | Last line `==> at the baseline` |

The step 2 loop:

```bash
end=$((SECONDS + 60))
while [ $SECONDS -lt $end ]; do
  R=$(kubectl -n rollback-demo get deploy rollback-demo -o jsonpath='{.spec.replicas}')
  T=$(kubectl -n argocd get app rollback-demo -o jsonpath='{.status.reconciledAt}')
  echo "$R replicas at $T"
  sleep 10
done
```

The self-heal timeout is 5 seconds, so 60 is long enough. The timestamp has to move: it is the
controller confirming it looked at the drift and left it alone. A timestamp that never moves means
nothing was tested. If self-heal reverts the drift to `1` replica, it synced to the revision that
was rolled back from, and the self-heal bullet in the docs is wrong.

### Case 3: per-app override off

The rollback has to be refused. This path was never exercised before the CRD was upgraded, because
`rollbackAware` was being pruned, so it has effectively never run.

| # | Action | Expected |
|---|---|---|
| B1 | `./rollback-demo.sh v3` | `pushed <sha>  v3: broken image (the bad one)`. This sha is **BAD** |
| B2 | Click **REFRESH** | No visible result yet |
| B3 | `./state.sh` | `sync: Synced at BAD`, `health: Progressing`, `pause line: (absent)` |
| 1 | `argocd app set rollback-demo --rollback-aware=false` | `application 'rollback-demo' updated`. Needs the branch CLI from section 1.4 |
| 2 | `./state.sh` | `rollbackAware: false`, which confirms the CRD is keeping the field |
| 3 | **Hard-reload** the browser tab, with Cmd-Shift-R | The UI re-reads the spec. A soft refresh is not enough |
| 4 | In the UI: **HISTORY AND ROLLBACK** -> topmost row whose `Revision` is not BAD -> **⋮** -> **Rollback** | **The assertion**: the dialog reads `Auto-Sync needs to be disabled in order for rollback to occur.` |
| 5 | Click **Cancel** | `./state.sh` still shows `record: (empty)` and `conds: (none)` |
| 6 | `argocd app rollback rollback-demo` | Fails with `rollback cannot be initiated when auto-sync is enabled`. The id is optional; section 3 explains why a wrong one misleads |
| 7 | `./restore-baseline.sh` | Last line `==> at the baseline`, and `rollbackAware` back to `inherited from argocd-cm` |

### Case 4: manual sync while paused

The documented deliberate-override path. A manual sync of the rolled-back revision clears the
record.

| # | Action | Expected |
|---|---|---|
| B1 | `./rollback-demo.sh v3` | `pushed <sha>  v3: broken image (the bad one)`. This sha is **BAD** |
| B2 | Click **REFRESH** | No visible result yet |
| B3 | `./state.sh` | `sync: Synced at BAD`, `health: Progressing`, `pause line: (absent)` |
| B4 | In the UI: **HISTORY AND ROLLBACK** -> topmost row whose `Revision` is not BAD -> **⋮** -> **Rollback** -> **OK** | Dialog reads `Auto-Sync stays enabled and will skip the current revision until ...`. The rollback is accepted |
| B5 | Click **REFRESH**, then `./state.sh` | `sync: OutOfSync at BAD`, `pause line: Auto sync skips rolled back revision BAD`, `record: BAD (plural field: 0 entries)`, `conds: AutoSyncPausedWarning` |
| 1 | `argocd app sync rollback-demo`, or **SYNC** then **SYNCHRONIZE** in the UI | The sync runs against BAD and succeeds |
| 2 | `./state.sh` | `sync: Synced at BAD`, `health: Progressing`, `pause line: (absent)`, `record: (empty) (plural field: 0 entries)`, `conds: (none)`, `last sync: id <n>  BAD  automated=false` |
| 3 | In the UI, look at the SYNC STATUS tile and the APP CONDITIONS tile | No `Auto sync skips rolled back revision` line, and no `1 Warning` chip |
| 4 | Run the watch loop below for 200 seconds | Every line keeps `rev` at BAD with `rolledBack` and `conds` empty, and `reconciledAt` moves at least once. **This is the assertion** |
| 5 | `./rollback-demo.sh fixfwd` | `pushed <sha>  v5: fix forward, three replicas` |
| 6 | Click **REFRESH**, then `./state.sh` | `sync: Synced at <v5 sha>`, `health` reaching `Healthy` |
| 7 | `./restore-baseline.sh` | Last line `==> at the baseline` |

The step 4 loop:

```bash
end=$((SECONDS + 200))
while [ $SECONDS -lt $end ]; do
  kubectl -n argocd get app rollback-demo -o json | jq -c '{
    reconciledAt: .status.reconciledAt,
    rev: .status.sync.revision[0:7],
    sync: .status.sync.status,
    rolledBack: (.status.rolledBackRevision // ""),
    conds: [.status.conditions[]?.type]
  }'
  sleep 20
done
```

One reconciliation interval is up to 3 minutes, so wait the full 200 seconds. `health: Progressing`
at step 2 is correct and stays correct throughout: you have deliberately deployed an image that
cannot be pulled, and a Deployment only turns `Degraded` once its `Progressing` condition carries
the reason `ProgressDeadlineExceeded` (`health_deployment.go:39`), which Kubernetes sets after
`progressDeadlineSeconds`, ten minutes by default.

`last sync: automated=false` at step 2 is what distinguishes this case: you synced it, not
auto-sync. The record is cleared by `persistRevisionHistory` (`state.go:1312`) after any successful
sync that is not itself a rollback, so this case passes whether or not the guard in `autoSync` is
correct. It is not a substitute for case 1.

### Case 5: rolling back twice replaces the record

A second rollback overwrites the record instead of accumulating. The controller decision has unit
coverage (`clears the record and syncs once the desired revision moves on`) and e2e coverage
(`TestAutoSyncRollbackAwareSecondRollbackReplacesRecord`). Steps 6 and 7 are the part only a person
can check.

| # | Action | Expected |
|---|---|---|
| B1 | `./rollback-demo.sh v3` | `pushed <sha>  v3: broken image (the bad one)`. This sha is **A** |
| B2 | Click **REFRESH** | No visible result yet |
| B3 | `./state.sh` | `sync: Synced at A`, `health: Progressing`, `pause line: (absent)` |
| B4 | In the UI: **HISTORY AND ROLLBACK** -> topmost row whose `Revision` is not A -> **⋮** -> **Rollback** -> **OK** | Dialog reads `Auto-Sync stays enabled and will skip the current revision until ...`. The rollback is accepted |
| B5 | Click **REFRESH**, then `./state.sh` | `sync: OutOfSync at A`, `pause line: Auto sync skips rolled back revision A`, `record: A (plural field: 0 entries)`, `conds: AutoSyncPausedWarning` |
| 1 | `./rollback-demo.sh v3b` | `pushed <sha>  v3b: another broken image`. This sha is **B**. It has a different tag and 3 replicas, so its manifests really differ from A |
| 2 | Click **REFRESH** | No visible result yet |
| 3 | `./state.sh` | `sync: Synced at B`, `health: Progressing`, `pause line: (absent)`, `record: (empty) (plural field: 0 entries)`, `conds: (none)`, `last sync: id <n>  B  automated=true` |
| 4 | `kubectl -n rollback-demo get deploy rollback-demo -o jsonpath='{.spec.replicas}{"\n"}{.spec.template.spec.containers[0].image}'; echo` | `3` and `nginx:no-such-tag-9570b`, which is B's manifests |
| 5 | Run the command below to get the `v1` history id, then in the UI: **HISTORY AND ROLLBACK** -> the row with that `Revision` -> **⋮** -> **Rollback** -> **OK**, then click **REFRESH** | The rollback is accepted |
| 6 | `./state.sh` | **The assertion**: `pause line: Auto sync skips rolled back revision B` naming B and not A, `record: B (plural field: 0 entries)` |
| 7 | `./state.sh`, same output | `sync: OutOfSync at B`, `conds: AutoSyncPausedWarning`, `health: Healthy`, because `v1` is a revision that runs |
| 8 | `./restore-baseline.sh` | Last line `==> at the baseline` |

The step 5 target:

```bash
GOOD=$(git -C ~/.argocd-dev/rollback-demo rev-list --max-parents=0 HEAD)
kubectl -n argocd get app rollback-demo -o json | jq -r --arg g "$GOOD" '
  [.status.history[] | select(.revision == $g)] | last
  | "roll back to history id \(.id), revision \(.revision[0:7])"'
```

`v1` is the only good revision in the fixture: both `v3` and `v3b` are broken images, and `v1` is
the repo's root commit, which is what that command keys on. Do not use the computed "newest entry
that is not current" from section 3 here. It would land on A, which tests the replacement correctly
but leaves a broken image deployed going into step 8.

`plural field: 0 entries` at step 6 is part of the pass. A single-source application uses the
singular field and leaves the plural one empty. A's sha would mean the second rollback appended
instead of replacing, which is the failure this case exists to catch.

### Case 6: instance default off, per-app on

The only place the two-tier resolution runs in the browser.

| # | Action | Expected |
|---|---|---|
| 1 | `kubectl -n argocd patch cm argocd-cm --type json -p '[{"op":"remove","path":"/data/application.rollbackAwareAutoSync"}]'` | `configmap/argocd-cm patched` |
| 2 | `curl -s http://localhost:8080/api/v1/settings \| jq .rollbackAwareAutoSyncEnabled` | `null`, not `false`: the field is `omitempty`, so it is absent when off. It reads `true` when the key is set. On a 401, skip this step; step 5 is the real assertion |
| 3 | `argocd app set rollback-demo --rollback-aware=true` | `application 'rollback-demo' updated` |
| 4 | **Hard-reload** the browser tab, with Cmd-Shift-R | Settings are fetched once per page load, so a soft refresh is not enough |
| B1 | `./rollback-demo.sh v3` | `pushed <sha>  v3: broken image (the bad one)`. This sha is **BAD** |
| B2 | Click **REFRESH** | No visible result yet |
| B3 | `./state.sh` | `sync: Synced at BAD`, `rollbackAware: true`, `auto sync: enabled` |
| 5 | In the UI: **HISTORY AND ROLLBACK** -> topmost row whose `Revision` is not BAD -> **⋮** -> **Rollback** | **The assertion**: the dialog reads `Auto-Sync stays enabled and will skip the current revision until ...`, resolved from the per-app value with the instance default off. Then click **OK** |
| 6 | Click **REFRESH**, then `./state.sh` | `sync: OutOfSync at BAD`, `pause line: Auto sync skips rolled back revision BAD`, `record: BAD (plural field: 0 entries)`, `conds: AutoSyncPausedWarning`, so the controller honors the per-app value too |
| 7 | `./rollback-demo.sh fixfwd`, then click **REFRESH** | `pushed <sha>  v5: fix forward, three replicas` |
| 8 | `./restore-baseline.sh` | Last line `==> at the baseline`. The script puts the `argocd-cm` key back |

Step 4 is where a problem would show. The old dialog wording after a hard reload points at the
settings round-trip, not at the fallback logic in the controller.


## 8. Restore baseline

Also saved next to this file as `restore-baseline.sh`. Needs a logged-in `argocd` CLI. It has two
modes, and both finish at the same baseline state:

| Mode | What it does | Cost |
|---|---|---|
| `./restore-baseline.sh` | Deletes the application, rebuilds the fixture repo at `v1`, recreates the application and lets auto-sync deploy it. History ends with a single entry | An app delete with prune, plus a create and a first sync |
| `./restore-baseline.sh --fast` | Pushes the good manifests forward and syncs, leaving the application and its history in place. Ends at `v5`, not `v1` | One push, one sync |

The clean reset is the default because that is what a case needs at `B1`. Step `B4` asks for "the
topmost row whose `Revision` is not BAD", and once a few cases have run, that panel holds a dozen
rows with repeated shas, so the right row is easy to miss.

Reach for `--fast` when you want the application working again without losing the history, for
instance to retry the second half of a case you have already set up. It pushes `fixfwd`, so it
leaves the application at `v5` with three replicas.

Neither mode rewinds the fixture repo on its own. The shas recorded in `status.history` are absent
from a rebuilt repo, so a rollback to one of those rows cannot resolve its revision. Rebuilding the
repo therefore requires deleting the application in the same step, which is why there is no git-only
reset.

```bash
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
```

A restored baseline prints:

```json
{"sync":"Synced","desired":"...","health":"Healthy","rolledBack":"",
 "conds":[],"histLen":1,"rollbackAware":"inherited"}
```

`argocd app sync` and `argocd app wait` are allowed to fail without aborting the script, because a
case that left a broken image deployed will not reach Healthy until `fixfwd` has been synced. The
script then checks the four fields that define the baseline and exits non-zero if any of them is
wrong, so a silently half-restored environment cannot be mistaken for a clean one. In the default
mode it also requires `histLen` to be exactly 1, which is the history a fresh application should
have. `--fast` grows `histLen` by design and is not checked against it.

The baseline is a state, not a particular revision, so neither mode checks which sha is deployed.
Both give auto-sync the first attempt at converging and only sync explicitly if that has not
happened within 60 seconds. Syncing unconditionally would add a second history entry at the same
revision, which is the duplicate row the clean reset exists to avoid.


## 9. Results log

| Case | Result | Date | Notes |
|---|---|---|---|
| 1 Fix forward | PASS | 2026-09-29 | |
| 2 Self-heal paused | PASS | 2026-09-29 | First live confirmation of the self-heal bullet in `auto_sync.md` |
| 3 Per-app override off | PASS | 2026-09-29 | First run of this path ever: `rollbackAware` was pruned by the old CRD |
| 4 Manual sync while paused | PASS | 2026-09-29 | |
| 5 Two rollbacks | PASS | 2026-09-29 | |
| 6 Instance off, per-app on | PASS | 2026-09-29 | |

All six on the build carrying the `!slices.Equal` guard fix. The earlier re-deploy of a rolled-back
revision does not reproduce.

## 10. Traps

| Symptom | Cause |
|---|---|
| Rollback accepted, then the bad revision re-deployed a second later | Pre-v3.6 Application CRD pruning all three fields. Check section 1.1 first |
| `ComparisonError: namespace ... is not managed` | Namespaced cluster registration missing the target namespace. Section 1.3 |
| A freshly recreated application immediately deploys the bad image | The fixture repo's `main` still points at the bad commit. Deleting and recreating the Application cannot change that, because `targetRevision: main` resolves to whatever was pushed last. Push a good revision, or run `init` for a clean repo (section 2) |
| `already at ..., nothing to push` | The stage you ran is already committed, so the desired revision did not move. Use a stage with different manifests |
| Rollback hits the wrong revision | A hard-coded history id, or a row repeating the current revision. Ids shift when the app is recreated. Sections 3 and 5 |
| `rollbackAware` reads `inherited` when the field is set to `false` | A jq `//` fallback treats `false` like a missing field. `has("rollbackAware")` is the only way to tell them apart. This bug was in `state.sh` and made case 3 step 2 unverifiable |
| Pause line with no warning chip | The record leaked. This was the stale-record bug, fixed by moving the guard above the `OutOfSync` early return in `autoSync` |
| Both `CreateNamespace=true` and `=false` in the spec | `argocd app set --sync-option` appends. Remove one with a JSON patch |
| Dialog shows the old wording after enabling the feature | Settings are read once per page load. Hard-reload the tab |
