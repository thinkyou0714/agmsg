#!/usr/bin/env bash
set -euo pipefail

# List (team, agent) pairs registered for a given (project_path, agent_type).
#
# Usage: identities.sh <project_path> <agent_type>
#
# Output: one "<team>\t<agent>" line per registered pair, tab-separated.
# Empty output (and exit 0) when no pair matches. Pairs are deduplicated.
#
# Used by:
#   - whoami.sh        — exact-match enumeration for identity resolution
#   - watch.sh         — subscription set for the monitor delivery mode
#   - check-inbox.sh   — turn-mode fallback enumeration

PROJECT_PATH="${1:?Usage: identities.sh <project_path> <agent_type>}"
AGENT_TYPE="${2:?Missing agent_type}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"

# After storage.sh is sourced so agmsg_sql_escape is defined.
PROJECT_SQL=$(agmsg_sql_escape "$PROJECT_PATH")
AGENT_TYPE_SQL=$(agmsg_sql_escape "$AGENT_TYPE")

[ -d "$TEAMS_DIR" ] || exit 0

for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue
  cfg_sql=$(agmsg_sql_readfile_path "$config_file")
  TEAM_NAME=$(agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
    SELECT json_extract(json, '\$.name') FROM cfg;
  ")
  [ -z "$TEAM_NAME" ] && continue
  [ "$TEAM_NAME" = "null" ] && continue
  TEAM_SQL=$(agmsg_sql_escape "$TEAM_NAME")

  sqlite3 -separator $'\t' :memory: "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
    agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
    )
    SELECT DISTINCT '$TEAM_SQL' AS team, name
    FROM agents, json_each(agents.registrations) AS r
    WHERE json_extract(r.value, '\$.project') = '$PROJECT_SQL'
      AND json_extract(r.value, '\$.type') = '$AGENT_TYPE_SQL'
    ORDER BY team, name;
  " | tr -d '\r'
done
