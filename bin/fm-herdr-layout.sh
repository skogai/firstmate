#!/usr/bin/env bash
# fm-herdr-layout.sh - opt-in persistent Herdr layout: named workspaces that
# exist before work is dispatched, receive this home's matching task tabs, and
# stay up when those tasks end.
#
# docs/herdr-backend.md "Persistent layout" owns the public contract (setting,
# identity, placement, limits). bin/fm-herdr-rules-lib.sh owns the rule
# grammar, and bin/backends/herdr.sh "persistent layout" owns the workspace
# identity, the anchor tab, and creation under the named-session lock. This
# header owns the commands.
#
# Off by default. bin/fm-spawn.sh guards its call with one file test on the
# home's config/herdr-layout, so while that file is absent this script is never
# run. An absent or "off" setting makes every command a no-op that contacts no
# Herdr server.
#
# Usage:
#   fm-herdr-layout.sh status
#   fm-herdr-layout.sh up
#   fm-herdr-layout.sh place <task> <project-path>
#
# status prints one "<workspace>\t<state>\t<ids>" line per declared workspace
# without starting a server or creating anything. <state> is present (one
# layout workspace, its id), missing, ambiguous (every matching id), unreadable,
# or server-stopped; <ids> is "-" when there is none.
# up starts the selected named session's server when it is not running and
# creates every missing declared workspace, printing
# "<workspace>\t<created|present|failed>\t<id or ->" per workspace. It is
# idempotent, so it is also the command that re-creates the layout after a
# Herdr server restart lost it.
# place prints "<session>:<workspace-id>" for the declared workspace a new task
# belongs in, creating that one workspace when it is missing, and prints
# nothing when the setting is off or no rule matches the task. On a failure it
# warns and exits 1, and bin/fm-spawn.sh falls back to the ordinary placement.
#
# New workspaces open in this home's directory. The selected named session is
# HERDR_SESSION, defaulting to Herdr's "default", exactly as for a spawn.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 on success or when off, 2 on a usage error, 1 when Herdr was
# unusable or a declared workspace could not be ensured.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# STATE is read by bin/fm-wake-lib.sh's lock functions, which the adapter
# sources before taking the named-session lock.
# shellcheck disable=SC2034
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_HERDR_LAYOUT_CONFIG="herdr-layout"

# shellcheck source=bin/fm-herdr-rules-lib.sh
. "$SCRIPT_DIR/fm-herdr-rules-lib.sh"

usage() {
  echo "usage: fm-herdr-layout.sh status | up | place <task> <project-path>" >&2
  exit 2
}

warn() {
  printf 'warning: herdr layout: %s\n' "$*" >&2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# Parsed setting: LAYOUT_ON is 1 when at least one workspace is declared, and
# DECLARED lists the declared names once each, in first-appearance order.
LAYOUT_ON=0
DECLARED=()

load_setting() {
  local file="$CONFIG/$FM_HERDR_LAYOUT_CONFIG" lower i name existing seen
  local -a names=() selectors=() ranks=()
  LAYOUT_ON=0
  DECLARED=()
  [ -f "$file" ] || return 0
  fm_herdr_rules_read "$file"
  if [ "${#FM_HERDR_RULE_LINES[@]}" -eq 1 ]; then
    lower=$(printf '%s' "${FM_HERDR_RULE_LINES[0]}" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      off) return 0 ;;
      on)
        warn "$file: \"on\" declares no workspace; write one \"<workspace> <selector>...\" line per workspace"
        return 0
        ;;
    esac
  fi
  fm_herdr_rules_parse "$file" workspace warn
  # A home's own flat workspace label stays the ordinary container's, so a
  # layout can never compete with it for the same label.
  i=0
  while [ "$i" -lt "${#FM_HERDR_RULE_NAME[@]}" ]; do
    name=${FM_HERDR_RULE_NAME[i]}
    case "$name" in
      firstmate|2ndmate-*)
        warn "$file: ignoring rule for workspace \"$name\" (reserved for a home's own workspace)"
        ;;
      *)
        names+=("$name")
        selectors+=("${FM_HERDR_RULE_SELECTORS[i]}")
        ranks+=("${FM_HERDR_RULE_RANK[i]}")
        seen=0
        for existing in ${DECLARED[@]+"${DECLARED[@]}"}; do
          [ "$existing" != "$name" ] || seen=1
        done
        [ "$seen" = 1 ] || DECLARED+=("$name")
        ;;
    esac
    i=$((i + 1))
  done
  FM_HERDR_RULE_NAME=(${names[@]+"${names[@]}"})
  FM_HERDR_RULE_SELECTORS=(${selectors[@]+"${selectors[@]}"})
  FM_HERDR_RULE_RANK=(${ranks[@]+"${ranks[@]}"})
  [ "${#DECLARED[@]}" -eq 0 ] || LAYOUT_ON=1
}

load_backend() {
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  fm_backend_source herdr || return 1
  SESSION=$(fm_backend_herdr_session)
  LAYOUT_CWD=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || LAYOUT_CWD=$FM_HOME
}

cmd_status() {
  local name running state ids status
  load_backend || return 1
  fm_backend_herdr_tool_check || return 1
  running=$(fm_backend_herdr_server_running_state "$SESSION")
  for name in "${DECLARED[@]}"; do
    ids=-
    if [ "$running" = stopped ]; then
      state=server-stopped
    elif [ "$running" != running ]; then
      state=unreadable
    else
      fm_backend_herdr_layout_workspace_find "$SESSION" "$name" && status=0 || status=$?
      case "$status" in
        0) state=present; ids=$FM_BACKEND_HERDR_LAYOUT_WS_ID ;;
        1) state=missing ;;
        2) state=ambiguous; ids=${FM_BACKEND_HERDR_LAYOUT_MATCHES// /,} ;;
        *) state=unreadable ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$name" "$state" "$ids"
  done
}

cmd_up() {
  local name rc=0
  load_backend || return 1
  fm_backend_herdr_version_check || return 1
  fm_backend_herdr_server_ensure "$SESSION" || return 1
  for name in "${DECLARED[@]}"; do
    if fm_backend_herdr_layout_workspace_ensure "$SESSION" "$name" "$LAYOUT_CWD"; then
      if [ "$FM_BACKEND_HERDR_LAYOUT_CREATED" = 1 ]; then
        printf '%s\tcreated\t%s\n' "$name" "$FM_BACKEND_HERDR_LAYOUT_WS_ID"
      else
        printf '%s\tpresent\t%s\n' "$name" "$FM_BACKEND_HERDR_LAYOUT_WS_ID"
      fi
    else
      printf '%s\tfailed\t-\n' "$name"
      rc=1
    fi
  done
  return "$rc"
}

cmd_place() { # <task> <project-path>
  local name
  fm_herdr_rules_match "$1" "$2" || return 0
  name=$FM_HERDR_RULE_MATCH_NAME
  if load_backend && fm_backend_herdr_version_check && fm_backend_herdr_server_ensure "$SESSION" &&
    fm_backend_herdr_layout_workspace_ensure "$SESSION" "$name" "$LAYOUT_CWD"; then
    printf '%s:%s\n' "$SESSION" "$FM_BACKEND_HERDR_LAYOUT_WS_ID"
    return 0
  fi
  warn "task $1 could not be placed in layout workspace \"$name\"; using the ordinary placement"
  return 1
}

cmd=${1:-}
case "$cmd" in
  status|up) [ "$#" -eq 1 ] || usage ;;
  place) { [ "$#" -eq 3 ] && task_ok "$2"; } || usage ;;
  *) usage ;;
esac

load_setting
if [ "$LAYOUT_ON" != 1 ]; then
  [ "$cmd" = place ] || echo "fm-herdr-layout: no workspace is declared in $CONFIG/$FM_HERDR_LAYOUT_CONFIG; nothing to do" >&2
  exit 0
fi

case "$cmd" in
  status) cmd_status ;;
  up) cmd_up ;;
  place) cmd_place "$2" "$3" ;;
esac
