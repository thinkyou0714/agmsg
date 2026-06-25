#!/usr/bin/env bash
# hook-input.sh — extract fields from a host-agent hook input payload.
#
# Hook entrypoints (session-start.sh, session-end.sh, check-inbox.sh) receive a
# small JSON object on stdin (e.g. {"session_id":"...", ...}). They only need a
# couple of flat string fields out of it, so this is a deliberately small,
# dependency-free sed match rather than a full JSON parser — the same idiom that
# was previously copy-pasted into each entrypoint. Centralizing it keeps the
# extraction consistent if the hook payload shape ever changes.

# Print the value of a top-level JSON string field, or nothing if absent.
# Usage: agmsg_hook_json_field <json> <field_name>
agmsg_hook_json_field() {
  local json="$1" field="$2"
  printf '%s' "$json" \
    | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -1
}
