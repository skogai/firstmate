#!/usr/bin/env bash
# tests/fm-herdr-layout.test.sh - the opt-in persistent Herdr layout, driven
# through bin/fm-herdr-layout.sh against a stateful scripted `herdr` CLI. No
# real Herdr server is started; tests/fm-herdr-layout-e2e.test.sh covers the
# real binary. docs/herdr-backend.md "Persistent layout" owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# A Herdr pane identity leaked in from the developer's own terminal must never
# route a call anywhere; every call here goes to the scripted fake.
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-herdr-layout)
SESSION="fm-layout-test-$$"

# make_fake_herdr <dir>: a stateful `herdr` stand-in. It logs every call (one
# line, unit-separated arguments) to $FAKE_HERDR_LOG and keeps workspaces and
# tabs in $FAKE_DIR/state.json: workspace create seeds tab "1" exactly like the
# real binary, tab create appends a tab, and pane close removes a tab and, with
# it, an emptied workspace. status reports the server stopped while
# $FAKE_DIR/stopped exists; `server` clears that.
make_fake_herdr() {  # <dir> -> fakebin
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$1/state.json"
  mkdir -p "$1/sock"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'herdr'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$FAKE_HERDR_LOG"
STATE="$FAKE_DIR/state.json"
q() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
ws=; label=; cwd=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i + 1))]:-} ;;
    --label) label=${args[$((i + 1))]:-} ;;
    --cwd) cwd=${args[$((i + 1))]:-} ;;
  esac
done
case "$1 ${2:-}" in
  "status --json")
    running=true
    [ ! -e "$FAKE_DIR/stopped" ] || running=false
    printf '{"client":{"version":"0.9.5","protocol":22},"server":{"running":%s,"version":"0.9.5","protocol":22}}\n' "$running"
    ;;
  "server "*|"server")
    rm -f "$FAKE_DIR/stopped"
    ;;
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s/sock/herdr.sock"}]}\n' "$HERDR_SESSION" "$FAKE_DIR"
    ;;
  "workspace list")
    q '{result:{workspaces:[.workspaces[] | {workspace_id, label, focused, active_tab_id}]}}'
    ;;
  "workspace create")
    n=$(q -r .next)
    w="w$n"
    focused=false
    [ "$(q '.workspaces | length')" -gt 0 ] || focused=true
    q --arg w "$w" --arg l "$label" --arg c "$cwd" --argjson f "$focused" '
      .workspaces += [{workspace_id:$w, label:$l, focused:$f, active_tab_id:($w + ":t1"), cwd:$c}]
      | .tabs += [{tab_id:($w + ":t1"), label:"1", workspace_id:$w, pane_id:($w + ":p1"), focused:true}]
      | .next += 1' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s:t1"},"root_pane":{"pane_id":"%s:p1"}}}\n' "$w" "$label" "$w" "$w"
    ;;
  "tab list")
    q --arg w "$ws" '{result:{tabs:[.tabs[] | select(.workspace_id == $w) | {tab_id, label, workspace_id, focused}]}}'
    ;;
  "tab create")
    n=$(q --arg w "$ws" '[.tabs[] | select(.workspace_id == $w)] | length + 1')
    while q -e --arg t "$ws:t$n" '[.tabs[] | select(.tab_id == $t)] | length > 0' >/dev/null; do n=$((n + 1)); done
    q --arg w "$ws" --arg l "$label" --arg t "$ws:t$n" --arg p "$ws:p$n" '
      .tabs += [{tab_id:$t, label:$l, workspace_id:$w, pane_id:$p, focused:false}]' | save
    printf '{"result":{"tab":{"tab_id":"%s:t%s"},"root_pane":{"pane_id":"%s:p%s"}}}\n' "$ws" "$n" "$ws" "$n"
    ;;
  "tab get")
    q --arg t "${3:-}" '{result:{tab:(.tabs[] | select(.tab_id == $t) | {tab_id, workspace_id})}}'
    ;;
  "tab focus") ;;
  "pane list")
    q --arg w "$ws" '{result:{panes:[.tabs[] | select(.workspace_id == $w) | {pane_id, tab_id}]}}'
    ;;
  "pane get")
    if q -e --arg p "${3:-}" 'any(.tabs[]; .pane_id == $p)' >/dev/null; then
      q --arg p "${3:-}" '{result:{pane:(.tabs[] | select(.pane_id == $p) | {pane_id, tab_id, workspace_id})}}'
    else
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "${3:-}"
      exit 1
    fi
    ;;
  "pane close")
    q --arg p "${3:-}" '.tabs |= [.[] | select(.pane_id != $p)]
      | . as $s | .workspaces |= [.[] | select(.workspace_id as $id | any($s.tabs[]; .workspace_id == $id))]' | save
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "${3:-}"
    ;;
  *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# new_home <name> [<secondmate-id>]: sets HOME_DIR, FAKE_DIR, FAKEBIN, and an
# empty log.
new_home() {
  FAKE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$FAKE_DIR/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$HOME_DIR/.fm-secondmate-home"
  FAKEBIN=$(make_fake_herdr "$FAKE_DIR")
  FAKE_HERDR_LOG="$FAKE_DIR/herdr.log"
  : > "$FAKE_HERDR_LOG"
}

layout() {  # <args...>: run the real script against the case home
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN:$PATH" HERDR_SESSION="$SESSION" \
    FAKE_DIR="$FAKE_DIR" FAKE_HERDR_LOG="$FAKE_HERDR_LOG" \
    "$ROOT/bin/fm-herdr-layout.sh" "$@"
}

calls() {  # <subcommand words...>: logged calls starting with them, readable
  local prefix="herdr" word
  for word in "$@"; do prefix="$prefix"$'\x1f'"$word"; done
  grep -a "^$prefix" "$FAKE_HERDR_LOG" | tr '\037' ' ' || true
}

seed_workspace() {  # <label> <tab-label...>: add a workspace with these tabs; prints its id
  local label=$1 n tab i=0
  shift
  n=$(jq -r .next "$FAKE_DIR/state.json")
  jq --arg w "w$n" --arg l "$label" '.workspaces += [{workspace_id:$w, label:$l, focused:(.workspaces | length == 0), active_tab_id:($w + ":t1")}] | .next += 1' \
    "$FAKE_DIR/state.json" > "$FAKE_DIR/state.tmp" && mv "$FAKE_DIR/state.tmp" "$FAKE_DIR/state.json"
  for tab in "$@"; do
    i=$((i + 1))
    jq --arg w "w$n" --arg l "$tab" --arg t "w$n:t$i" --arg p "w$n:p$i" '.tabs += [{tab_id:$t, label:$l, workspace_id:$w, pane_id:$p, focused:false}]' \
      "$FAKE_DIR/state.json" > "$FAKE_DIR/state.tmp" && mv "$FAKE_DIR/state.tmp" "$FAKE_DIR/state.json"
  done
  printf 'w%s\n' "$n"
}

workspace_tabs() {  # <workspace-id>: its tab labels, comma-joined
  jq -r --arg w "$1" '[.tabs[] | select(.workspace_id == $w) | .label] | join(",")' "$FAKE_DIR/state.json"
}

test_absent_off_or_bare_on_setting_does_nothing() {
  local out
  new_home off
  out=$(layout place web-1 /p/storefront 2>&1) || fail "place failed with the setting absent: $out"
  assert_equals "" "$out" "place output with the setting absent"
  out=$(layout up 2>&1) || fail "up failed with the setting absent: $out"
  assert_contains "$out" "no workspace is declared" "up names the missing declaration"
  printf ' OFF \n' > "$HOME_DIR/config/herdr-layout"
  out=$(layout status 2>&1) || fail "status failed with the setting off: $out"
  out=$(layout place web-1 /p/storefront 2>&1) || fail "place failed with the setting off: $out"
  assert_equals "" "$out" "place output with the setting off"
  printf 'on\n' > "$HOME_DIR/config/herdr-layout"
  out=$(layout up 2>&1) || fail "up failed with a bare on: $out"
  assert_contains "$out" '"on" declares no workspace' "a bare on warns instead of guessing a workspace"
  assert_equals "" "$(cat "$FAKE_HERDR_LOG")" "herdr calls while the layout is off"
  pass "absent, off, or bare on setting: nothing is placed and not a single Herdr call"
}

test_rules_route_tasks_and_reject_bad_or_reserved_names() {
  local out err
  new_home rules
  cat > "$HOME_DIR/config/herdr-layout" <<'EOF'
# routing
web    task:web repo:storefront
api    repo:api-server
Bad/Name task:x
firstmate *
2ndmate-x task:y
misc   bogus
misc   *
EOF
  err="$FAKE_DIR/err"
  out=$(layout status 2>"$err") || fail "status failed: $out"
  assert_contains "$(cat "$err")" 'invalid workspace name "Bad/Name"' "invalid name warning"
  assert_contains "$(cat "$err")" 'workspace "firstmate" (reserved' "the primary home label is reserved"
  assert_contains "$(cat "$err")" 'workspace "2ndmate-x" (reserved' "secondmate home labels are reserved"
  assert_contains "$(cat "$err")" 'unknown selector "bogus"' "unknown selector warning"
  assert_equals $'web\tmissing\t-\napi\tmissing\t-\nmisc\tmissing\t-' "$out" "status lists each declared workspace once, in order"
  assert_equals "" "$(calls workspace create)" "status never creates"

  out=$(layout place web-1 /p/api-server 2>/dev/null) || fail "place web-1 failed: $out"
  assert_equals "$SESSION:$(jq -r '.workspaces[] | select(.label == "web") | .workspace_id' "$FAKE_DIR/state.json")" "$out" \
    "a task-id prefix beats a repository selector"
  out=$(layout place fix-2 /p/api-server 2>/dev/null) || fail "place fix-2 failed: $out"
  assert_contains "$out" "$SESSION:" "a repository selector places its task"
  [ "$(jq -r --arg w "${out#*:}" '.workspaces[] | select(.workspace_id == $w) | .label' "$FAKE_DIR/state.json")" = api ] ||
    fail "fix-2 should land in the api workspace"
  out=$(layout place other-3 /p/elsewhere 2>/dev/null) || fail "place other-3 failed: $out"
  [ "$(jq -r --arg w "${out#*:}" '.workspaces[] | select(.workspace_id == $w) | .label' "$FAKE_DIR/state.json")" = misc ] ||
    fail "the catch-all workspace takes an otherwise unmatched task"
  pass "rules: task prefix beats repo beats catch-all; bad and reserved names warn and never route"
}

test_up_creates_once_and_never_adopts_by_label_alone() {
  local out decoy foreign crew
  new_home create
  printf 'crew *\n' > "$HOME_DIR/config/herdr-layout"
  decoy=$(seed_workspace crew 1)
  foreign=$(seed_workspace crew 'layout·2ndmate-other')
  out=$(layout up 2>&1) || fail "up failed: $out"
  crew=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "crew" && $2 == "created" { print $3 }')
  [ -n "$crew" ] && [ "$crew" != "$decoy" ] && [ "$crew" != "$foreign" ] ||
    fail "up must create its own crew workspace instead of adopting a label match: $out"
  assert_contains "$(calls workspace create)" "workspace create --cwd $HOME_DIR --label crew --no-focus" \
    "the workspace opens in this home's directory, unfocused"
  assert_contains "$(calls tab create)" "tab create --workspace $crew --cwd $HOME_DIR --label layout·firstmate --no-focus" \
    "the anchor tab carries this home's label"
  assert_equals 'layout·firstmate' "$(workspace_tabs "$crew")" "only the anchor remains after the seeded default tab is pruned"
  assert_equals '1' "$(workspace_tabs "$decoy")" "the label-only decoy is untouched"
  assert_equals 'layout·2ndmate-other' "$(workspace_tabs "$foreign")" "another home's layout workspace is untouched"
  : > "$FAKE_HERDR_LOG"
  out=$(layout up 2>&1) || fail "second up failed: $out"
  assert_equals $'crew\tpresent\t'"$crew" "$out" "a second up finds the workspace present"
  assert_equals "" "$(calls workspace create)$(calls tab create)" "a second up creates nothing"
  pass "up: creates once with its anchor, then is idempotent, and never adopts by label alone"
}

test_place_creates_lazily_and_task_cleanup_keeps_the_workspace() {
  local out crew task_pane
  new_home lazy
  printf 'crew task:cm\n' > "$HOME_DIR/config/herdr-layout"
  out=$(layout place cm-1 /p/x) || fail "place failed: $out"
  crew=${out#*:}
  assert_equals 'layout·firstmate' "$(workspace_tabs "$crew")" "place creates a missing workspace with its anchor"
  # Simulate the spawn's task tab and its later cleanup through the real
  # adapter primitives fm-spawn.sh and fm-teardown.sh use.
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  task_pane=$(env PATH="$FAKEBIN:$PATH" HERDR_SESSION="$SESSION" FAKE_DIR="$FAKE_DIR" FAKE_HERDR_LOG="$FAKE_HERDR_LOG" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '
      . "$1/bin/backends/herdr.sh"
      ids=$(fm_backend_herdr_create_task "$2" fm-cm-1 /p/x "") || exit 1
      printf "%s" "${ids#* }"' _ "$ROOT" "$out") || fail "task tab create failed"
  assert_equals 'layout·firstmate,fm-cm-1' "$(workspace_tabs "$crew")" "the task tab joins the anchor without a prune"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  env PATH="$FAKEBIN:$PATH" HERDR_SESSION="$SESSION" FAKE_DIR="$FAKE_DIR" FAKE_HERDR_LOG="$FAKE_HERDR_LOG" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '
      . "$1/bin/backends/herdr.sh"
      fm_backend_herdr_kill "$2"' _ "$ROOT" "$SESSION:$task_pane" || fail "task kill failed"
  assert_equals 'layout·firstmate' "$(workspace_tabs "$crew")" "task cleanup closes only the task tab"
  out=$(layout status) || fail "status failed: $out"
  assert_equals $'crew\tpresent\t'"$crew" "$out" "the layout workspace survives task cleanup"
  pass "place: creates a missing workspace on demand, and task cleanup never removes it"
}

test_ambiguity_and_a_stopped_server_are_reported_not_guessed() {
  local out a b
  new_home ambiguous
  printf 'crew *\n' > "$HOME_DIR/config/herdr-layout"
  a=$(seed_workspace crew 'layout·firstmate')
  b=$(seed_workspace crew 'layout·firstmate' fm-old)
  out=$(layout status) || fail "status failed: $out"
  assert_equals $'crew\tambiguous\t'"$a,$b" "$out" "status names every matching workspace"
  out=$(layout place web-1 /p/x 2>&1) && fail "place must refuse an ambiguous layout workspace: $out"
  assert_contains "$out" "more than one herdr layout workspace" "place names the ambiguity"
  assert_contains "$out" "using the ordinary placement" "place tells the spawn to fall back"
  out=$(layout up 2>/dev/null) && fail "up must fail on an ambiguous layout workspace: $out"
  assert_equals $'crew\tfailed\t-' "$out" "up reports the ambiguous workspace as failed"
  assert_equals "" "$(calls workspace create)" "ambiguity never creates a third workspace"

  new_home stopped
  printf 'crew *\n' > "$HOME_DIR/config/herdr-layout"
  touch "$FAKE_DIR/stopped"
  out=$(layout status) || fail "status failed with a stopped server: $out"
  assert_equals $'crew\tserver-stopped\t-' "$out" "status reports a stopped server"
  assert_equals "" "$(calls server)" "status never starts a server"
  pass "ambiguous workspaces and a stopped server are reported, never guessed at or started"
}

test_secondmate_home_uses_its_own_anchor() {
  local out crew
  new_home secondmate sm1
  printf 'crew *\n' > "$HOME_DIR/config/herdr-layout"
  seed_workspace crew 'layout·firstmate' >/dev/null
  out=$(layout up 2>&1) || fail "up failed in a secondmate home: $out"
  crew=$(printf '%s\n' "$out" | awk -F '\t' '$2 == "created" { print $3 }')
  [ -n "$crew" ] || fail "a secondmate home must not adopt the primary's layout workspace: $out"
  assert_equals 'layout·2ndmate-sm1' "$(workspace_tabs "$crew")" "the secondmate home's anchor carries its own label"
  pass "secondmate home: its layout workspaces are its own, never the primary's"
}

test_absent_off_or_bare_on_setting_does_nothing
test_rules_route_tasks_and_reject_bad_or_reserved_names
test_up_creates_once_and_never_adopts_by_label_alone
test_place_creates_lazily_and_task_cleanup_keeps_the_workspace
test_ambiguity_and_a_stopped_server_are_reported_not_guessed
test_secondmate_home_uses_its_own_anchor
