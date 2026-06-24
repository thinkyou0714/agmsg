#!/usr/bin/env bash
# grok-build delivery plug — dedicated JSON hook file (.grok/hooks/agmsg.json).
#
# Grok Build has no Monitor-tool equivalent, so the manifest declares
# delivery_modes="turn off"; delivery.sh's central gate rejects monitor/both
# before this runs (and before any file is touched). Modeled on the copilot
# plug: a fully agmsg-owned hook file we write/remove wholesale (not a merge
# into a shared settings file). The Stop hook runs check-inbox.sh, which reads
# `session_id` from the hook input JSON on stdin — Grok Build emits the same
# Claude-Code-shaped event, so no env remap is needed here. Uses
# resolve_hooks_file + SKILL_DIR from delivery.sh's sourced context.
#
# C-GATED (#214): the exact hook filename + JSON schema below are the assumed
# Claude-Code shape (xAI's official schema page was not directly fetchable). Do
# NOT treat this as final — confirm against a real install with `grok inspect`
# and adjust the file path (manifest hooks_file=) and the JSON keys if they
# differ. Everything else in this type (manifest, template, whoami detect,
# install SKILL placement, join) is schema-independent and stands as-is.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")

  # Strip first so re-applying turn is an idempotent rewrite and turn->off
  # cleanly removes the file.
  rm -f "$hooks_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$hooks_file")"
    local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
    local cmd_json
    cmd_json=$(agmsg_sqlite_mem "SELECT json_quote('$(printf '%s' "$cmd" | sed "s/'/''/g")');")
    # Stop trigger (PascalCase) so the input payload's snake_case session_id
    # field matches what check-inbox.sh already parses.
    cat <<EOF > "$hooks_file"
{
  "version": 1,
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "bash": $cmd_json,
        "timeoutSec": 30
      }
    ]
  }
}
EOF
  fi
}
