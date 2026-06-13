#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env

  # Stub the agent CLIs so `command -v` succeeds without the real tools, and
  # provide a `record.sh` that captures the launch command instead of opening
  # a terminal. PATH is prepended so the stubs win.
  export STUB_BIN="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$STUB_BIN"
  for bin in claude codex; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$bin"
    chmod +x "$STUB_BIN/$bin"
  done
  export CAPTURE="$TEST_SKILL_DIR/launch-capture.txt"
  cat > "$STUB_BIN/record.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
EOF
  chmod +x "$STUB_BIN/record.sh"
  export PATH="$STUB_BIN:$PATH"

  # Never inherit a real tmux server from the test runner — force the
  # OS-terminal path, which we redirect into record.sh via a {cmd} template.
  unset TMUX
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"

  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
}

teardown() {
  teardown_test_env
}

# --- argument validation ---

@test "spawn: rejects unsupported agent type (gemini)" {
  run bash "$SCRIPTS/spawn.sh" gemini foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported by spawn yet" ]]
}

@test "spawn: rejects unknown agent type" {
  run bash "$SCRIPTS/spawn.sh" frobnicate foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown agent type" ]]
}

@test "spawn: requires a name" {
  run bash "$SCRIPTS/spawn.sh" claude-code
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage" ]]
}

@test "spawn: rejects invalid --split" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ" --split z
  [ "$status" -ne 0 ]
  [[ "$output" =~ "--split must be" ]]
}

@test "spawn: rejects a nonexistent project" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project /no/such/dir
  [ "$status" -ne 0 ]
  [[ "$output" =~ "project path does not exist" ]]
}

@test "spawn: errors when the target CLI is not installed" {
  rm -f "$STUB_BIN/codex"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # Restrict PATH so a real codex installed on the host can't satisfy the
  # check — only the stub dir (now lacking codex) plus system utilities.
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$SCRIPTS/spawn.sh" codex foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not found on PATH" ]]
}

# --- team resolution ---

@test "spawn: errors when no team is registered for the project" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no team is registered" ]]
}

@test "spawn: errors when the project belongs to multiple teams without --team" {
  bash "$SCRIPTS/join.sh" team-a existing-a claude-code "$PROJ"
  bash "$SCRIPTS/join.sh" team-b existing-b codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "multiple teams" ]]
}

@test "spawn: --team disambiguates a multi-team project" {
  bash "$SCRIPTS/join.sh" team-a existing-a claude-code "$PROJ"
  bash "$SCRIPTS/join.sh" team-b existing-b codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --team team-b
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" =~ team-b$'\t'alice ]]
}

# --- happy path / launch command ---

@test "spawn: pre-joins the name and launches the CLI with the actas prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "spawned claude-code 'alice'" ]]

  # alice is now registered to the resolved team.
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" =~ "alice" ]]

  # The launch command cd'd into the project and ran claude with the actas
  # slash command as the initial prompt. (printf %q escapes the spaces in the
  # prompt as "\ ", so assert on individual tokens rather than the phrase.)
  run cat "$CAPTURE"
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"agmsg"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"$PROJ"* ]]
}

@test "spawn: errors when \$TMUX is set but tmux is not on PATH" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # $TMUX set (we look like we're inside tmux) but a PATH that lacks the tmux
  # binary — only the stub dir (claude/codex) plus system utilities.
  run env TMUX="/tmp/fake,1,0" PATH="$STUB_BIN:/usr/bin:/bin" \
    bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tmux binary is not on PATH" ]]
}

@test "spawn: codex spawns the codex CLI" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  run cat "$CAPTURE"
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"reviewer"* ]]
}

# --- pre-flight exclusivity check ---

@test "spawn: refuses when the name is held by another live session" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$PROJ"
  # Forge a live owner for (myteam, alice).
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  printf '%s\n' LIVESID > "$TEST_SKILL_DIR/run/actas.myteam__alice.session"

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "held by a live session" ]]
}
