#!/usr/bin/env bash
# Real-Herdr E2E for the opt-in persistent layout (docs/herdr-backend.md
# "Persistent layout"), driving the real bin/fm-herdr-layout.sh, fm-spawn.sh,
# and fm-teardown.sh.
# Every production Herdr call is routed through one guarded named non-default
# lab, the mid-run server restart uses only the helper's guarded stop and
# re-provision, and lab teardown verifies that the default fleet session is
# byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo 'skip: treehouse not found (required by fm-spawn.sh)'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# Spawn here has no Herdr parent pane, so an identity inherited from the
# terminal running the suite must not follow it into the lab.
herdr_forget_inherited_pane

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-layout-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
# The scratch project's worktree pool lives under the temp root, so cleanup
# removes it with everything else. Exported before provisioning, because a
# Herdr pane inherits the server's startup environment.
export TREEHOUSE_ROOT="$TMP_ROOT/treehouse"
WTS=()
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-layout)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$? wt
  for wt in ${WTS[@]+"${WTS[@]}"}; do
    treehouse return --force "$wt" >/dev/null 2>&1 || true
  done
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision the isolated Herdr lab session'

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH"
export HERDR_SESSION="$HERDR_LAB_SESSION"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
focus_snapshot() {
  lab workspace list | jq -r '[.result.workspaces[] | select(.focused == true)] | if length == 1 then "\(.[0].workspace_id)\t\(.[0].active_tab_id)" else "ambiguous" end'
}
workspace_label() { # <workspace-id>
  lab workspace list | jq -r --arg ws "$1" '.result.workspaces[] | select(.workspace_id == $ws) | .label'
}
workspace_count() {
  lab workspace list | jq '.result.workspaces | length'
}
tab_labels() { # <workspace-id>
  lab tab list --workspace "$1" | jq -r '[.result.tabs[].label] | join(",")'
}
layout() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-herdr-layout.sh" "$@"
}
field() { # <tsv-output> <workspace> <column>
  printf '%s\n' "$1" | awk -F '\t' -v ws="$2" -v col="$3" '$1 == ws { print $col }'
}
meta() { # <task> <key>
  sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta" | tail -1
}
spawn_task() { # <task> <project>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nExercise layout placement.\n\n## Firstmate spec\nNothing to build.\n' > "$HOME_DIR/data/$1/brief.md"
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$2" "sh -c 'echo $1-ok'" --mode no-mistakes --yolo off --backend herdr \
    >"$TMP_ROOT/$1.out" 2>"$TMP_ROOT/$1.err" ||
    fail "spawn of $1 failed"$'\n'"$(cat "$TMP_ROOT/$1.out" "$TMP_ROOT/$1.err")"
  WTS+=("$(meta "$1" worktree)")
}
teardown_task() { # <task>
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" "$1" >"$TMP_ROOT/$1.td" 2>&1 ||
    fail "teardown of $1 failed"$'\n'"$(cat "$TMP_ROOT/$1.td")"
}

make_scratch_project() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  printf '# scratch\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$1" "$1.origin.git"
  git -C "$1" remote add origin "file://$1.origin.git"
}
PROJECT="$TMP_ROOT/scratch-project"
make_scratch_project "$PROJECT"

# The home forces the presentation projection on and owns its flat parent, so
# a task the layout does not claim visibly takes the ordinary projected path.
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/config/herdr-layout" <<'EOF'
# persistent layout for the e2e home
crew task:cm
other repo:never-matches
EOF

ANCHOR=$(lab workspace create --cwd "$TMP_ROOT" --label captain-anchor --focus) || fail 'could not create the focus anchor'
ANCHOR_WS=$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')
lab workspace create --cwd "$TMP_ROOT" --label firstmate --no-focus >/dev/null || fail 'could not create the home workspace'
# A foreign workspace that merely shares a declared name - on Herdr 0.9.5 an
# unlabeled workspace opened in a directory named "crew" reports exactly this
# label - must never be adopted.
DECOY=$(lab workspace create --cwd "$TMP_ROOT" --label crew --no-focus) || fail 'could not create the decoy workspace'
DECOY_WS=$(printf '%s' "$DECOY" | jq -r '.result.workspace.workspace_id')
FOCUS_BEFORE=$(focus_snapshot)

out=$(layout status) || fail "status failed: $out"
[ "$(field "$out" crew 2)" = missing ] && [ "$(field "$out" other 2)" = missing ] ||
  fail "status before up should report both declared workspaces missing"$'\n'"$out"
pass 'status reports declared workspaces missing and ignores a decoy that only shares the label'

out=$(layout up) || fail "up failed: $out"
CREW_WS=$(field "$out" crew 3)
OTHER_WS=$(field "$out" other 3)
[ "$(field "$out" crew 2)" = created ] && [ "$(field "$out" other 2)" = created ] ||
  fail "up should create both declared workspaces"$'\n'"$out"
[ -n "$CREW_WS" ] && [ "$CREW_WS" != "$DECOY_WS" ] && [ "$CREW_WS" != "$OTHER_WS" ] ||
  fail "up should create its own crew workspace, not adopt the decoy"$'\n'"$out"
[ "$(workspace_label "$CREW_WS")" = crew ] || fail 'the created crew workspace carries the declared label'
[ "$(tab_labels "$CREW_WS")" = 'layout·firstmate' ] ||
  fail "the created crew workspace holds exactly its anchor tab, got '$(tab_labels "$CREW_WS")'"
[ "$(focus_snapshot)" = "$FOCUS_BEFORE" ] || fail 'up must not move focus'
COUNT=$(workspace_count)
pass 'up creates each declared workspace with its anchor tab, without adopting the decoy or moving focus'

out=$(layout up) || fail "second up failed: $out"
[ "$(field "$out" crew 2)" = present ] && [ "$(field "$out" crew 3)" = "$CREW_WS" ] &&
  [ "$(field "$out" other 2)" = present ] && [ "$(field "$out" other 3)" = "$OTHER_WS" ] ||
  fail "a second up should find both workspaces present"$'\n'"$out"
[ "$(workspace_count)" = "$COUNT" ] || fail 'a second up must not create anything'
pass 'up is idempotent'

spawn_task cm-a "$PROJECT"
[ "$(meta cm-a herdr_workspace_id)" = "$CREW_WS" ] ||
  fail "a matched task should land in the crew workspace, got $(meta cm-a herdr_workspace_id)"$'\n'"$(cat "$TMP_ROOT/cm-a.err")"
[ "$(tab_labels "$CREW_WS")" = 'layout·firstmate,fm-cm-a' ] ||
  fail "the crew workspace should hold its anchor and the task tab, got '$(tab_labels "$CREW_WS")'"
[ ! -e "$HOME_DIR/state/cm-a.herdr-presentation" ] || fail 'a layout-placed task must not start a projection'
sleep 1
lab pane read "$(meta cm-a herdr_pane_id)" --lines 200 | grep -q 'cm-a-ok' || fail "cm-a's launch command did not run in its layout tab"
pass 'a matched task lands as a tab in its layout workspace instead of a projection'

spawn_task un1 "$PROJECT"
UN1_WS=$(meta un1 herdr_workspace_id)
case "$(workspace_label "$UN1_WS")" in
  '└ un1 · p:'*) ;;
  *) fail "an unmatched task should keep the ordinary projected path, got '$(workspace_label "$UN1_WS")'" ;;
esac
pass 'an unmatched task keeps the ordinary placement'

CMA_PANE=$(meta cm-a herdr_pane_id)
teardown_task cm-a
[ ! -e "$HOME_DIR/state/cm-a.meta" ] || fail 'teardown did not remove the task record'
lab pane get "$CMA_PANE" 2>&1 | jq -e '.error.code == "pane_not_found"' >/dev/null ||
  fail "teardown did not close cm-a's pane"
[ "$(workspace_label "$CREW_WS")" = crew ] || fail 'cleanup of a layout task must leave its workspace up'
[ "$(tab_labels "$CREW_WS")" = 'layout·firstmate' ] ||
  fail "cleanup should close only the task tab, got '$(tab_labels "$CREW_WS")'"
out=$(layout status)
[ "$(field "$out" crew 2)" = present ] && [ "$(field "$out" crew 3)" = "$CREW_WS" ] ||
  fail "the layout should still report crew present after cleanup"$'\n'"$out"
pass 'task cleanup closes only the task tab and the layout workspace stays up'

env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'guarded lab stop failed'
out=$(layout status) || fail "status with a stopped server failed: $out"
[ "$(field "$out" crew 2)" = server-stopped ] || fail "status must not start a stopped server"$'\n'"$out"
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'guarded lab restart failed'
out=$(layout up) || fail "up after a restart failed: $out"
[ "$(field "$out" crew 2)" = present ] && [ "$(field "$out" crew 3)" = "$CREW_WS" ] ||
  fail "a restored crew workspace should be found again after a server restart"$'\n'"$out"
pass 'after a Herdr server restart, up finds the restored layout workspaces'

# A lost layout workspace re-forms on the next routed spawn.
lab workspace close "$CREW_WS" >/dev/null || fail 'could not close the crew workspace'
spawn_task cm-b "$PROJECT"
NEW_CREW_WS=$(meta cm-b herdr_workspace_id)
[ "$NEW_CREW_WS" != "$CREW_WS" ] && [ "$(workspace_label "$NEW_CREW_WS")" = crew ] ||
  fail "a routed spawn should re-create the lost crew workspace"
[ "$(tab_labels "$NEW_CREW_WS")" = 'layout·firstmate,fm-cm-b' ] ||
  fail "the re-created crew workspace should hold its anchor and the task tab, got '$(tab_labels "$NEW_CREW_WS")'"
out=$(layout status)
[ "$(field "$out" crew 3)" = "$NEW_CREW_WS" ] || fail "status should report the re-created crew workspace"$'\n'"$out"
pass 'a routed spawn re-creates a lost layout workspace'

teardown_task cm-b
teardown_task un1
[ "$(workspace_label "$NEW_CREW_WS")" = crew ] && [ "$(workspace_label "$OTHER_WS")" = other ] ||
  fail 'the layout workspaces should outlive every task'
[ "$(workspace_label "$ANCHOR_WS")" = captain-anchor ] && [ "$(workspace_label "$DECOY_WS")" = crew ] ||
  fail 'the layout must never touch a workspace it did not create'
pass 'the layout outlives every task and never touches foreign workspaces'
