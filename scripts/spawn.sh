#!/usr/bin/env bash
set -euo pipefail

# spawn.sh — launch a NEW agent process and have it take an actas identity.
#
# Given an agent-type and an actas <name>, spawn.sh:
#   1. pre-joins <name> to a team for the target project (so the child's
#      actas flow just claims the role instead of prompting for a team),
#   2. opens a place to run it — a tmux pane/window when run inside tmux,
#      otherwise an OS terminal window,
#   3. launches the agent CLI there with `/agmsg actas <name>` as its
#      initial prompt, so the new agent comes up already registered and
#      addressable.
#
# Usage:
#   spawn.sh <agent-type> <name> [options]
#
#   <agent-type>   claude-code | codex   (only these two are supported today)
#   <name>         actas identity for the spawned agent
#
# Options:
#   --project <path>   project to launch in (default: $PWD)
#   --team <team>      team to join <name> into (default: auto-resolved from
#                      the project's existing registrations; required when the
#                      project belongs to more than one team)
#   --window           open a new tmux WINDOW instead of splitting the pane
#                      (only meaningful inside tmux)
#   --split h|v        tmux split direction when splitting the current window
#                      (h = left/right [default], v = top/bottom)
#   --terminal <tmpl>  terminal command template for the non-tmux path; a
#                      `{cmd}` placeholder is replaced with the launch command.
#                      Overrides $AGMSG_TERMINAL and config `spawn.terminal`.
#
# Scope note: claude-code/codex only; macOS is the primary target, Linux and
# Windows are best-effort (no guarantee — please open an issue/PR if a given
# terminal does not work). Headless environments (no tmux and no usable
# terminal) error out, because the agent CLIs need an interactive terminal.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
TEAMS_DIR="$SKILL_DIR/teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"

die() { echo "spawn: $*" >&2; exit 1; }

# --- Parse positional args ---
AGENT_TYPE="${1:-}"
NAME="${2:-}"
[ -n "$AGENT_TYPE" ] || die "Usage: spawn.sh <agent-type> <name> [options]"
[ -n "$NAME" ] || die "Usage: spawn.sh <agent-type> <name> [options]"
shift 2 || true

case "$AGENT_TYPE" in
  claude-code|codex) ;;
  gemini|antigravity|copilot)
    die "agent type '$AGENT_TYPE' is not supported by spawn yet (supported: claude-code, codex)" ;;
  *)
    die "unknown agent type '$AGENT_TYPE' (supported: claude-code, codex)" ;;
esac

# --- Parse options ---
PROJECT="$PWD"
TEAM=""
TMUX_TARGET="pane"   # pane | window
SPLIT="h"            # h | v
TERMINAL_TMPL=""     # --terminal override (resolved below if empty)

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --team)    TEAM="${2:?--team needs a name}"; shift 2 ;;
    --window)  TMUX_TARGET="window"; shift ;;
    --split)   SPLIT="${2:?--split needs h|v}"; shift 2 ;;
    --terminal) TERMINAL_TMPL="${2:?--terminal needs a template}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$SPLIT" in h|v) ;; *) die "--split must be 'h' or 'v'" ;; esac

# Resolve the terminal override for the non-tmux path:
#   --terminal  >  $AGMSG_TERMINAL  >  config spawn.terminal
# A value containing a `{cmd}` placeholder is treated as a command template
# on every platform. A bare value (no placeholder) is honored only on macOS,
# as an app-name hint (e.g. "iterm"); on Linux/Windows a bare value is an
# error, since those paths need an explicit template to know how to invoke it.
if [ -z "$TERMINAL_TMPL" ]; then
  TERMINAL_TMPL="${AGMSG_TERMINAL:-}"
fi
if [ -z "$TERMINAL_TMPL" ]; then
  TERMINAL_TMPL="$("$SCRIPT_DIR/config.sh" get spawn.terminal "" 2>/dev/null || true)"
fi

is_terminal_template() { [[ "$1" == *"{cmd}"* ]]; }

# Normalize the project path so registrations/lookups are consistent with the
# rest of agmsg (which keys on the path as given by the caller's pwd).
if [ ! -d "$PROJECT" ]; then
  die "project path does not exist: $PROJECT"
fi
PROJECT="$(cd "$PROJECT" && pwd)"

# --- Resolve the target CLI and make sure it is installed ---
case "$AGENT_TYPE" in
  claude-code) CLI_BIN="claude" ;;
  codex)       CLI_BIN="codex" ;;
esac
command -v "$CLI_BIN" >/dev/null 2>&1 \
  || die "'$CLI_BIN' not found on PATH — install the ${AGENT_TYPE} CLI first"

# --- Resolve the team to join <name> into ---
# When --team is omitted, derive it from any team that already has an agent
# registered for this project (any type). Zero or many → require --team.
resolve_team() {
  [ -d "$TEAMS_DIR" ] || return 0
  local config_file team_name escaped count_for_project
  local found=""
  for config_file in "$TEAMS_DIR"/*/config.json; do
    [ -f "$config_file" ] || continue
    escaped=$(sed "s/'/''/g" "$config_file")
    team_name=$(sqlite3 :memory: ".param set :json '$escaped'" \
      "SELECT json_extract(:json, '\$.name');")
    # Does any agent in this team have a registration for PROJECT?
    count_for_project=$(sqlite3 :memory: ".param set :json '$escaped'" "
      WITH agents AS (
        SELECT
          CASE
            WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
            ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
          END AS registrations
        FROM json_each(json_extract(:json, '\$.agents'))
      )
      SELECT COUNT(*)
      FROM agents, json_each(agents.registrations) AS r
      WHERE json_extract(r.value, '\$.project') = '$PROJECT';
    ")
    if [ "${count_for_project:-0}" -gt 0 ]; then
      found="${found:+$found
}$team_name"
    fi
  done
  printf '%s' "$found"
}

if [ -z "$TEAM" ]; then
  CANDIDATES="$(resolve_team)"
  CAND_COUNT=$(printf '%s' "$CANDIDATES" | grep -c . || true)
  if [ "$CAND_COUNT" -eq 1 ]; then
    TEAM="$CANDIDATES"
  elif [ "$CAND_COUNT" -eq 0 ]; then
    die "no team is registered for this project; pass --team <team>"
  else
    die "project belongs to multiple teams ($(printf '%s' "$CANDIDATES" | paste -sd, -)); pass --team <team>"
  fi
fi

# --- Pre-flight: refuse if <name> is currently held by another live session ---
# The child's actas flow would refuse anyway; failing here avoids launching a
# process that immediately can't take its identity.
STATE="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$STATE" in
  other:*)
    die "actas '$NAME' in team '$TEAM' is held by a live session (${STATE#other:}); drop it there first" ;;
esac

# --- Pre-join so the child's actas just claims (no interactive team prompt) ---
"$SCRIPT_DIR/join.sh" "$TEAM" "$NAME" "$AGENT_TYPE" "$PROJECT" >/dev/null

# --- Build the launch command ---
# The agent CLIs accept an initial prompt as a positional argument and submit
# it as the session's first message; passing the slash command makes the new
# agent run `/agmsg actas <name>` on boot. We cd into the project first so a
# cross-project spawn lands in the right tree.
ACTAS_PROMPT="/agmsg actas ${NAME}"
LAUNCH="cd $(printf '%q' "$PROJECT") && ${CLI_BIN} $(printf '%q' "$ACTAS_PROMPT")"

# ============================================================================
# Placement
# ============================================================================

launch_in_tmux() {
  # $TMUX is set (we are inside a tmux pane), but the `tmux` client binary
  # still has to be on PATH for split-window/new-window to work. In a
  # PATH-starved environment (e.g. spawned indirectly from cron/CI into a
  # tmux pane) it may be missing. Fail fast with a clear message rather than
  # aborting on a raw "tmux: command not found", and don't silently fall back
  # to an OS terminal — opening a separate window while inside tmux is more
  # confusing than an explicit error.
  command -v tmux >/dev/null 2>&1 \
    || die "\$TMUX is set but the tmux binary is not on PATH; add it to PATH, or run outside tmux to use the OS-terminal path"

  # Run the launch command in a fresh shell so $(printf %q) escaping holds,
  # regardless of tmux's default-command shell.
  local run="bash -lc $(printf '%q' "$LAUNCH")"
  if [ "$TMUX_TARGET" = "window" ]; then
    tmux new-window -c "$PROJECT" "$run"
  else
    local dir="-h"; [ "$SPLIT" = "v" ] && dir="-v"
    tmux split-window "$dir" -c "$PROJECT" "$run"
  fi
}

# Escape a string for embedding inside an AppleScript double-quoted literal.
applescript_quote() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

launch_macos_terminal() {
  local app="${1:-Terminal}"
  local esc; esc="$(applescript_quote "$LAUNCH")"
  case "$app" in
    iterm|iterm2|iTerm|iTerm2)
      osascript \
        -e 'tell application "iTerm"' \
        -e '  create window with default profile' \
        -e "  tell current session of current window to write text \"$esc\"" \
        -e '  activate' \
        -e 'end tell' >/dev/null
      ;;
    *)
      osascript \
        -e "tell application \"Terminal\" to do script \"$esc\"" \
        -e 'tell application "Terminal" to activate' >/dev/null
      ;;
  esac
}

launch_linux_terminal() {
  # Keep the window open after the agent exits so the operator can see final
  # output; `exec bash` drops to an interactive shell in the project dir.
  local run="bash -lc $(printf '%q' "$LAUNCH; exec bash")"
  local term
  for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
      gnome-terminal) gnome-terminal --working-directory="$PROJECT" -- bash -lc "$LAUNCH; exec bash" ;;
      konsole)        konsole --workdir "$PROJECT" -e bash -lc "$LAUNCH; exec bash" ;;
      *)              "$term" -e bash -lc "$LAUNCH; exec bash" ;;
    esac
    return 0
  done
  die "no supported terminal emulator found (tried gnome-terminal/konsole/xterm/...); set AGMSG_TERMINAL or run inside tmux"
}

launch_windows_terminal() {
  if command -v wt.exe >/dev/null 2>&1; then
    wt.exe new-tab bash -lc "$LAUNCH"
    return 0
  fi
  if command -v wt >/dev/null 2>&1; then
    wt new-tab bash -lc "$LAUNCH"
    return 0
  fi
  die "Windows Terminal (wt) not found; set AGMSG_TERMINAL or run inside tmux"
}

launch_with_template() {
  # User-supplied terminal command. Substitute {cmd} with a self-contained
  # launch invocation; if there is no placeholder, append it.
  local inner; inner="bash -lc $(printf '%q' "$LAUNCH")"
  local cmd
  if [[ "$TERMINAL_TMPL" == *"{cmd}"* ]]; then
    cmd="${TERMINAL_TMPL//\{cmd\}/$inner}"
  else
    cmd="$TERMINAL_TMPL $inner"
  fi
  bash -c "$cmd"
}

place_and_launch() {
  if [ -n "${TMUX:-}" ]; then
    launch_in_tmux
    echo "spawned ${AGENT_TYPE} '${NAME}' in tmux (${TMUX_TARGET})"
    return 0
  fi

  # Non-tmux: open an OS terminal. A {cmd} template wins outright on any OS.
  if [ -n "$TERMINAL_TMPL" ] && is_terminal_template "$TERMINAL_TMPL"; then
    launch_with_template
    echo "spawned ${AGENT_TYPE} '${NAME}' via custom terminal template"
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      # Bare override (no {cmd}) is an app-name hint here, e.g. "iterm".
      launch_macos_terminal "${TERMINAL_TMPL:-Terminal}" ;;
    Linux)
      if [ -n "$TERMINAL_TMPL" ]; then
        die "AGMSG_TERMINAL/spawn.terminal must contain a {cmd} placeholder on Linux (got: $TERMINAL_TMPL)"
      fi
      # No display → cannot open a GUI terminal, and there is no tmux to fall
      # back to. The agent CLI needs an interactive terminal, so error.
      if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        die "headless environment: no tmux session and no display available — cannot open a terminal for ${CLI_BIN}. Run inside tmux, or set a {cmd} terminal template via AGMSG_TERMINAL."
      fi
      launch_linux_terminal ;;
    MINGW*|MSYS*|CYGWIN*)
      if [ -n "$TERMINAL_TMPL" ]; then
        die "AGMSG_TERMINAL/spawn.terminal must contain a {cmd} placeholder on Windows (got: $TERMINAL_TMPL)"
      fi
      launch_windows_terminal ;;
    *)
      die "unsupported platform '$(uname -s)' for the non-tmux path; run inside tmux or set a {cmd} terminal template via AGMSG_TERMINAL." ;;
  esac
  echo "spawned ${AGENT_TYPE} '${NAME}' in a new terminal window"
}

place_and_launch
