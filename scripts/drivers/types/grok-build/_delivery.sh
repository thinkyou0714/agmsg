#!/usr/bin/env bash
# grok-build delivery plug — dedicated JSON hook file (.grok/hooks/agmsg.json).
#
# Grok Build has no Monitor-tool equivalent, so the manifest declares
# delivery_modes="turn off"; delivery.sh's central gate rejects monitor/both
# before this runs (and before any file is touched). Modeled on the copilot
# plug: a fully agmsg-owned hook file we write/remove wholesale (not a merge
# into a shared settings file). The Stop hook runs check-inbox.sh between turns.
# Uses resolve_hooks_file + SKILL_DIR from delivery.sh's sourced context.
#
# Schema confirmed against a real Grok Build install (xAI local docs
# ~/.grok/docs/user-guide/10-hooks.md): the hook file is the Claude-Code-shaped
# nested form { "hooks": { "Stop": [ { "hooks": [ { "type":"command",
# "command":<abs>, "timeout":N } ] } ] } } at <project>/.grok/hooks/agmsg.json
# (no top-level "version"). Grok injects GROK_SESSION_ID/CLAUDE_PROJECT_DIR into
# every hook and emits the session id on stdin as camelCase "sessionId"; the
# shared session-start.sh / check-inbox.sh resolve that (snake_case session_id ->
# camelCase sessionId -> $GROK_SESSION_ID) so no per-type remap is needed here.
# `command` is the absolute check-inbox.sh path ($SKILL_DIR is absolute).
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
    # Stop = "agent turn ends" (lifecycle event, no matcher). Nested Claude shape:
    # Stop[].hooks[] each { type:"command", command:<abs>, timeout:<sec> }.
    cat <<EOF > "$hooks_file"
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": $cmd_json,
            "timeout": 30
          }
        ]
      }
    ]
  }
}
EOF
  fi
}

# Status derives the mode from the hook file's existence, not by parsing the
# Claude/Codex nested-settings shape the default status reader expects — our
# hook file is the dedicated agmsg-owned form (present => turn, absent => off).
# Same override copilot uses. Schema-independent: only checks file presence.
agmsg_delivery_status() { rulefile_status "$@"; }
