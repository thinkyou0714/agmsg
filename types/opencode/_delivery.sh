#!/usr/bin/env bash
# opencode delivery plug — markdown rule-file, but turn|off only (no Monitor-tool
# equivalent, so monitor/both are rejected). Uses resolve_hooks_file + SKILL_DIR
# from delivery.sh's sourced context.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  case "$mode" in
    turn|off) ;;
    monitor|both)
      echo "Error: '$mode' mode is not supported for $type (no Monitor-tool equivalent). Use 'turn' or 'off'." >&2
      return 1
      ;;
    *)
      echo "Unknown mode: $mode (use turn|off)" >&2
      return 1
      ;;
  esac

  rm -f "$rule_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$rule_file")"
    cat <<EOF > "$rule_file"
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
EOF
  fi
}
agmsg_delivery_status() { rulefile_status "$@"; }
