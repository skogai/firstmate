#!/usr/bin/env bash
# fm-herdr-rules-lib.sh - the rule-line grammar shared by the Herdr settings
# that route tasks by name: project groups (config/herdr-project-groups,
# bin/fm-herdr-groups.sh) and the persistent layout (config/herdr-layout,
# bin/fm-herdr-layout.sh).
#
# docs/herdr-backend.md "Group rules" owns the public grammar. This header owns
# the mechanics: a rule line is a name followed by whitespace-separated
# selectors (task:<prefix>, repo:<name>, or *); a name uses letters, digits,
# ".", "_", "+", and "-" and is at most 32 characters; the order in which a name
# first appears is its rank, so one name may span several lines. Blank lines and
# lines starting with "#" are not rules.
#
# Functions:
#   fm_herdr_rules_read <file>
#     FM_HERDR_RULE_LINES = the file's trimmed rule-candidate lines, in order.
#     A missing file leaves it empty.
#   fm_herdr_rules_parse <file> <noun> <warn-function>
#     Parses FM_HERDR_RULE_LINES into the parallel arrays FM_HERDR_RULE_NAME,
#     FM_HERDR_RULE_SELECTORS (space-separated), and FM_HERDR_RULE_RANK.
#     An invalid name drops its line and an unknown selector is kept but never
#     matches; each is reported once through <warn-function>, naming <file> and
#     calling the name a <noun>.
#   fm_herdr_rules_match <task> <project-path>
#     Sets FM_HERDR_RULE_MATCH_NAME and FM_HERDR_RULE_MATCH_RANK and returns 0
#     for the winning rule, or returns 1 when no rule matches. Task-id prefixes
#     win over repository names, which win over "*", across all rules; within
#     one selector kind the first matching line wins. The repository name is the
#     project path's last component, or "unknown" for an empty path.
#
# Sourced only; it sets no shell options and runs nothing at source time.

FM_HERDR_RULE_LINES=()
FM_HERDR_RULE_NAME=()
FM_HERDR_RULE_SELECTORS=()
FM_HERDR_RULE_RANK=()
FM_HERDR_RULE_MATCH_NAME=
FM_HERDR_RULE_MATCH_RANK=

fm_herdr_rules_read() { # <file>
  local file=$1 line trimmed
  FM_HERDR_RULE_LINES=()
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    case "$trimmed" in ''|'#'*) continue ;; esac
    FM_HERDR_RULE_LINES+=("$trimmed")
  done < "$file"
}

fm_herdr_rules_parse() { # <file> <noun> <warn-function>
  local file=$1 noun=$2 warn_fn=$3 line name selectors selector rank i names=0
  local -a sels=()
  FM_HERDR_RULE_NAME=()
  FM_HERDR_RULE_SELECTORS=()
  FM_HERDR_RULE_RANK=()
  for line in ${FM_HERDR_RULE_LINES[@]+"${FM_HERDR_RULE_LINES[@]}"}; do
    read -r name selectors <<EOF
$line
EOF
    case "$name" in
      *[!A-Za-z0-9._+-]*|'')
        "$warn_fn" "$file: ignoring rule with invalid $noun name \"$name\" (letters, digits, . _ + - only)"
        continue
        ;;
    esac
    if [ "${#name}" -gt 32 ]; then
      "$warn_fn" "$file: ignoring rule for $noun \"$name\" (at most 32 characters)"
      continue
    fi
    read -r -a sels <<EOF
$selectors
EOF
    for selector in ${sels[@]+"${sels[@]}"}; do
      case "$selector" in
        'task:'?*|'repo:'?*|'*') ;;
        *) "$warn_fn" "$file: $noun \"$name\": ignoring unknown selector \"$selector\" (task:<prefix>, repo:<name>, or *)" ;;
      esac
    done
    rank=
    i=0
    while [ "$i" -lt "${#FM_HERDR_RULE_NAME[@]}" ]; do
      [ "${FM_HERDR_RULE_NAME[i]}" = "$name" ] && { rank=${FM_HERDR_RULE_RANK[i]}; break; }
      i=$((i + 1))
    done
    [ -n "$rank" ] || { names=$((names + 1)); rank=$names; }
    FM_HERDR_RULE_NAME+=("$name")
    FM_HERDR_RULE_SELECTORS+=("$selectors")
    FM_HERDR_RULE_RANK+=("$rank")
  done
}

fm_herdr_rules_match() { # <task> <project-path>
  local task=$1 project=${2%/} repo i selector kind
  local -a sels=()
  repo=${project##*/}
  [ -n "$repo" ] || repo=unknown
  FM_HERDR_RULE_MATCH_NAME=
  FM_HERDR_RULE_MATCH_RANK=
  for kind in task repo any; do
    i=0
    while [ "$i" -lt "${#FM_HERDR_RULE_NAME[@]}" ]; do
      read -r -a sels <<EOF
${FM_HERDR_RULE_SELECTORS[i]}
EOF
      for selector in ${sels[@]+"${sels[@]}"}; do
        case "$kind:$selector" in
          task:task:?*)
            case "$task" in "${selector#task:}"|"${selector#task:}"-*) ;; *) continue ;; esac
            ;;
          repo:repo:?*)
            [ "$repo" = "${selector#repo:}" ] || continue
            ;;
          'any:*') ;;
          *) continue ;;
        esac
        # shellcheck disable=SC2034 # Read by the sourcing script after a match.
        FM_HERDR_RULE_MATCH_NAME=${FM_HERDR_RULE_NAME[i]}
        # shellcheck disable=SC2034 # Read by the sourcing script after a match.
        FM_HERDR_RULE_MATCH_RANK=${FM_HERDR_RULE_RANK[i]}
        return 0
      done
      i=$((i + 1))
    done
  done
  return 1
}
